//! PeerModel: applies a diff with begin/endInsertRows, begin/endRemoveRows and
//! dataChanged. It never resets, so surviving rows keep their identity.

use core::pin::Pin;
use std::sync::atomic::{AtomicI32, Ordering};

use cxx_qt::CxxQtType;
use cxx_qt_lib::{QByteArray, QHash, QList, QHashPair_i32_QByteArray, QModelIndex, QString, QVariant};

use crate::bridge::qobject::PeerModel;
use crate::peers::{diff, parse, Peer, RowOp};

const ROLE_NAME: i32 = 0x0100 + 1; // Qt::UserRole + 1
const ROLE_ONLINE: i32 = 0x0100 + 2;

// Process-wide counts of PeerModels, so a test can see each one destroyed
// exactly once (check 7c). The library outlives each engine.
pub static LIVE_MODELS: AtomicI32 = AtomicI32::new(0);
pub static CREATED_MODELS: AtomicI32 = AtomicI32::new(0);

pub struct PeerModelRust {
    peers: Vec<Peer>,
}

impl Default for PeerModelRust {
    fn default() -> Self {
        LIVE_MODELS.fetch_add(1, Ordering::SeqCst);
        CREATED_MODELS.fetch_add(1, Ordering::SeqCst);
        Self { peers: Vec::new() }
    }
}

impl Drop for PeerModelRust {
    fn drop(&mut self) {
        LIVE_MODELS.fetch_sub(1, Ordering::SeqCst);
    }
}

impl PeerModel {
    pub fn row_count(&self, _parent: &QModelIndex) -> i32 {
        self.rust().peers.len() as i32
    }

    pub fn data(&self, index: &QModelIndex, role: i32) -> QVariant {
        let Some(peer) = self.rust().peers.get(index.row() as usize) else {
            return QVariant::default();
        };
        match role {
            ROLE_NAME => QVariant::from(&QString::from(peer.name.as_str())),
            ROLE_ONLINE => QVariant::from(&peer.online),
            _ => QVariant::default(),
        }
    }

    pub fn role_names(&self) -> QHash<QHashPair_i32_QByteArray> {
        let mut roles = QHash::<QHashPair_i32_QByteArray>::default();
        roles.insert(ROLE_NAME, QByteArray::from("name"));
        roles.insert(ROLE_ONLINE, QByteArray::from("online"));
        roles
    }

    pub fn apply_text(self: Pin<&mut Self>, line: &QString) {
        self.apply(parse(&line.to_string()));
    }

    /// Applies `new` as a sequence of row operations computed by `peers::diff`.
    pub fn apply(mut self: Pin<&mut Self>, new: Vec<Peer>) {
        let root = QModelIndex::default();
        for op in diff(&self.rust().peers, &new) {
            match op {
                RowOp::Remove(row) => {
                    let r = row as i32;
                    self.as_mut().begin_remove_rows(&root, r, r);
                    self.as_mut().rust_mut().peers.remove(row);
                    self.as_mut().end_remove_rows();
                }
                RowOp::Insert(row, peer) => {
                    let r = row as i32;
                    self.as_mut().begin_insert_rows(&root, r, r);
                    self.as_mut().rust_mut().peers.insert(row, peer);
                    self.as_mut().end_insert_rows();
                }
                RowOp::Change(row, peer) => {
                    self.as_mut().rust_mut().peers[row] = peer;
                    let idx = self.model_index(row as i32, 0, &root);
                    self.as_mut().data_changed(&idx, &idx, &QList::default());
                }
            }
        }
    }
}
