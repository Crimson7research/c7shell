//! The QML bridge (plan decision P7): the `Probe` singleton of the
//! harness-only module `C7Harness`.
//!
//! Rust emits `command(json)`; the driver's handler runs it against
//! `Tailscale` and calls `reply(json)` before the emit returns, because a
//! signal on the same thread is delivered directly. So a read is
//! synchronous and needs no wait.

use std::cell::{Cell, RefCell};
use std::pin::Pin;

use cxx_qt_lib::QString;

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qml_singleton]
        type Probe = super::ProbeRust;

        /// A command for the driver, as JSON.
        #[qsignal]
        fn command(self: Pin<&mut Probe>, json: QString);

        /// The driver's answer to the command being emitted.
        #[qinvokable]
        fn reply(self: &Probe, json: &QString);

        /// The driver has connected its signal counters.
        #[qinvokable]
        fn ready(self: &Probe);
    }

    impl cxx_qt::Initialize for Probe {}
}

thread_local! {
    static INSTANCE: Cell<*mut qobject::Probe> = const { Cell::new(std::ptr::null_mut()) };
    static READY: Cell<bool> = const { Cell::new(false) };
    static REPLY: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// The Rust half of a `Probe`. It holds nothing: the live instance and the
/// pending reply are thread-locals, so a reentrant `reply` never touches a
/// field the emit has borrowed.
#[derive(Default)]
pub struct ProbeRust;

impl Drop for ProbeRust {
    fn drop(&mut self) {
        INSTANCE.with(|i| i.set(std::ptr::null_mut()));
        READY.with(|r| r.set(false));
    }
}

impl cxx_qt::Initialize for qobject::Probe {
    fn initialize(self: Pin<&mut Self>) {
        // SAFETY: the pointer is only dereferenced on this thread while the
        // engine owning the singleton is alive; Drop clears it.
        let ptr = unsafe { self.get_unchecked_mut() as *mut qobject::Probe };
        INSTANCE.with(|i| i.set(ptr));
    }
}

impl qobject::Probe {
    fn reply(&self, json: &QString) {
        REPLY.with(|r| *r.borrow_mut() = Some(json.to_string()));
    }

    fn ready(&self) {
        READY.with(|r| r.set(true));
    }
}

/// Whether the driver has said it is ready.
pub fn is_ready() -> bool {
    READY.with(Cell::get)
}

/// Emits `json` to the driver and returns its reply.
pub fn send(json: &str) -> Result<String, String> {
    let ptr = INSTANCE.with(Cell::get);
    if ptr.is_null() {
        return Err("no Probe: the driver is not loaded".into());
    }
    REPLY.with(|r| r.borrow_mut().take());
    // SAFETY: see initialize(); the instance is alive while non-null.
    unsafe { Pin::new_unchecked(&mut *ptr) }.command(QString::from(json));
    REPLY.with(|r| r.borrow_mut().take()).ok_or_else(|| format!("the driver did not reply to {json}"))
}
