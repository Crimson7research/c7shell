//! Contract: the QML singleton `Contract` (Rust type ContractObject). It
//! exercises the Qt features the #286 TailscaleBackend contract uses that
//! round 1 did not: a named singleton, a Q_ENUM property, owned model
//! properties, QDateTime/QStringList, a shared NOTIFY, a derived signal and a
//! backend chosen at construction.

use core::pin::Pin;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use cxx::UniquePtr;
use cxx_qt::casting::Upcast;
use cxx_qt::{CxxQtType, Threading};
use cxx_qt_lib::{QDateTime, QObjectExt, QString, QStringList, QTimeZone};

use crate::backend::{self, ContractBackend, Sink};
use crate::bridge::qobject::{peer_model_new, ContractObject, PeerModel, QAbstractListModel, State};
use crate::peer_model::{CREATED_MODELS, LIVE_MODELS};
use crate::snapshot::{exit_node_blocked, Snapshot};
use crate::spike::thread_names;

pub struct ContractRust {
    // Declared first, so it is dropped first: the backend (and its tokio
    // runtime) stops before the models it feeds go away.
    driver: Box<dyn ContractBackend>,
    pub(crate) state: State,
    pub(crate) key_expiry: QDateTime,
    pub(crate) issues: QStringList,
    pub(crate) exit_node_active: bool,
    pub(crate) exit_node_online: bool,
    pub(crate) backend: QString,
    pub(crate) revision: i32,
    // Owned by the singleton: created here, deleted when this struct drops,
    // which happens inside the singleton's C++ destructor.
    peers: UniquePtr<PeerModel>,
    exit_nodes: UniquePtr<PeerModel>,
}

impl Default for ContractRust {
    fn default() -> Self {
        let driver = backend::from_env();
        let backend = QString::from(driver.name());
        Self {
            driver,
            state: State::NoState,
            key_expiry: QDateTime::default(), // invalid: "does not expire"
            issues: QStringList::default(),
            exit_node_active: false,
            exit_node_online: false,
            backend,
            revision: 0,
            peers: peer_model_new(),
            exit_nodes: peer_model_new(),
        }
    }
}

impl cxx_qt::Initialize for ContractObject {
    fn initialize(mut self: Pin<&mut Self>) {
        // 7e: the derived signal is wired here, so a backend cannot forget it.
        self.as_mut().on_exit_node_active_changed(|o| o.exit_node_blocked_changed()).release();
        self.as_mut().on_exit_node_online_changed(|o| o.exit_node_blocked_changed()).release();

        // 7c: parent the owned models to the singleton too, so the QML engine
        // treats them as owned by C++ (never garbage-collected). They are still
        // deleted by the UniquePtr; deleting a child unregisters it from its parent.
        let models = [self.rust().peers.as_mut_ptr(), self.rust().exit_nodes.as_mut_ptr()];
        for model in models {
            // SAFETY: both models are live (owned by self) and distinct from
            // self; `me` is only used for the duration of this call.
            unsafe {
                let me: *mut ContractObject = self.as_mut().get_unchecked_mut();
                let base: Pin<&mut QAbstractListModel> = Pin::new_unchecked(&mut *model).upcast_pin();
                base.set_parent(Pin::new_unchecked(&mut *me));
            }
        }

        // 7f: the backend delivers snapshots; they are applied on the Qt thread.
        let thread = self.qt_thread();
        let sink: Sink = Arc::new(move |snapshot: Snapshot| {
            // Err means the singleton is gone; the snapshot is dropped unapplied.
            let _ = thread.queue(move |o: Pin<&mut ContractObject>| o.apply(snapshot));
        });
        self.as_mut().rust_mut().driver.start(sink);
    }
}

/// Which signals one snapshot needs. Values are stored first and emitted
/// second, so a slot reading a sibling property never sees a stale value.
#[derive(Default)]
struct Changed {
    state: bool,
    key_expiry: bool,
    issues: bool,
    active: bool,
    online: bool,
}

impl ContractObject {
    fn apply(mut self: Pin<&mut Self>, s: Snapshot) {
        let mut changed = Changed::default();
        {
            let mut r = self.as_mut().rust_mut();
            if let Some(i) = s.state {
                let st = State { repr: i };
                changed.state = r.state != st;
                r.state = st;
            }
            if let Some(expiry) = s.key_expiry_ms {
                let new = match expiry {
                    Some(ms) => QDateTime::from_msecs_since_epoch(ms, &QTimeZone::utc()),
                    None => QDateTime::default(),
                };
                changed.key_expiry = r.key_expiry != new;
                r.key_expiry = new;
            }
            if let Some(issues) = s.issues {
                let new: QStringList = issues.iter().map(|i| QString::from(i.as_str())).collect();
                changed.issues = r.issues != new;
                r.issues = new;
            }
            if let Some(a) = s.exit_node_active {
                changed.active = r.exit_node_active != a;
                r.exit_node_active = a;
            }
            if let Some(o) = s.exit_node_online {
                changed.online = r.exit_node_online != o;
                r.exit_node_online = o;
            }
            // The models emit their own row signals as they apply the diff.
            if let Some(p) = s.peers {
                r.peers.pin_mut().apply(p);
            }
            if let Some(p) = s.exit_nodes {
                r.exit_nodes.pin_mut().apply(p);
            }
            r.revision += 1;
        }
        if changed.state {
            self.as_mut().state_changed();
        }
        if changed.key_expiry {
            self.as_mut().key_expiry_changed();
        }
        if changed.issues {
            self.as_mut().issues_changed(); // one signal for issues AND issueCount
        }
        if changed.active {
            self.as_mut().exit_node_active_changed(); // -> exitNodeBlockedChanged
        }
        if changed.online {
            self.as_mut().exit_node_online_changed(); // -> exitNodeBlockedChanged
        }
        self.as_mut().revision_changed();
    }

    pub fn issue_count(&self) -> i32 {
        self.rust().issues.len() as i32
    }

    pub fn exit_node_blocked(&self) -> bool {
        exit_node_blocked(self.rust().exit_node_active, self.rust().exit_node_online)
    }

    pub fn peers_model(&self) -> *mut PeerModel {
        self.rust().peers.as_mut_ptr()
    }

    pub fn exit_nodes_model(&self) -> *mut PeerModel {
        self.rust().exit_nodes.as_mut_ptr()
    }

    pub fn feed(&self, line: &QString) -> bool {
        self.rust().driver.feed(&line.to_string())
    }

    pub fn backend_threads(&self) -> i32 {
        thread_names().iter().filter(|n| n.starts_with(backend::THREAD_NAME)).count() as i32
    }

    pub fn live_models(&self) -> i32 {
        LIVE_MODELS.load(Ordering::SeqCst)
    }

    pub fn created_models(&self) -> i32 {
        CREATED_MODELS.load(Ordering::SeqCst)
    }

    pub fn models_parented_to_self(&self) -> bool {
        let me = self as *const ContractObject as *const cxx_qt::QObject;
        let r = self.rust();
        [&r.peers, &r.exit_nodes]
            .iter()
            .all(|m| m.as_ref().is_some_and(|m| Upcast::<QAbstractListModel>::upcast(m).parent() == me))
    }
}
