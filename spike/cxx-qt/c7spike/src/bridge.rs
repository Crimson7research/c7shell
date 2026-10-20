//! The cxx-qt bridge: the QML-facing types. cxx-qt-build generates the C++
//! side into target/; nothing here is hand-written C++.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
        include!("cxx-qt-lib/qbytearray.h");
        type QByteArray = cxx_qt_lib::QByteArray;
        include!("cxx-qt-lib/qmodelindex.h");
        type QModelIndex = cxx_qt_lib::QModelIndex;
        include!("cxx-qt-lib/qvariant.h");
        type QVariant = cxx_qt_lib::QVariant;
        include!("cxx-qt-lib/qhash.h");
        type QHash_i32_QByteArray = cxx_qt_lib::QHash<cxx_qt_lib::QHashPair_i32_QByteArray>;
        include!("cxx-qt-lib/qlist.h");
        type QList_i32 = cxx_qt_lib::QList<i32>;
    }

    unsafe extern "C++Qt" {
        include!(<QtCore/QAbstractListModel>);
        // `base = QObject` gives QAbstractListModel an Upcast<QObject> (a
        // static_cast to an indirect base), so a PeerModel can be parented.
        #[qobject]
        #[base = QObject]
        type QAbstractListModel;
    }

    // ---- PeerModel: a list model with stable rows -------------------------
    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[base = QAbstractListModel]
        type PeerModel = super::PeerModelRust;
    }

    unsafe extern "RustQt" {
        #[cxx_override]
        #[cxx_name = "rowCount"]
        fn row_count(self: &PeerModel, parent: &QModelIndex) -> i32;

        #[cxx_override]
        fn data(self: &PeerModel, index: &QModelIndex, role: i32) -> QVariant;

        #[cxx_override]
        #[cxx_name = "roleNames"]
        fn role_names(self: &PeerModel) -> QHash_i32_QByteArray;

        /// Applies "a=1,b=0" synchronously (used by QML tests that bypass tokio).
        #[qinvokable]
        #[cxx_name = "applyText"]
        fn apply_text(self: Pin<&mut PeerModel>, line: &QString);

        #[inherit]
        #[cxx_name = "beginInsertRows"]
        fn begin_insert_rows(self: Pin<&mut PeerModel>, parent: &QModelIndex, first: i32, last: i32);
        #[inherit]
        #[cxx_name = "endInsertRows"]
        fn end_insert_rows(self: Pin<&mut PeerModel>);
        #[inherit]
        #[cxx_name = "beginRemoveRows"]
        fn begin_remove_rows(self: Pin<&mut PeerModel>, parent: &QModelIndex, first: i32, last: i32);
        #[inherit]
        #[cxx_name = "endRemoveRows"]
        fn end_remove_rows(self: Pin<&mut PeerModel>);
        #[inherit]
        #[cxx_name = "index"]
        fn model_index(self: &PeerModel, row: i32, column: i32, parent: &QModelIndex) -> QModelIndex;
        #[qsignal]
        #[inherit]
        #[cxx_name = "dataChanged"]
        fn data_changed(
            self: Pin<&mut PeerModel>,
            top_left: &QModelIndex,
            bottom_right: &QModelIndex,
            roles: &QList_i32,
        );
    }

    impl cxx_qt::Threading for PeerModel {}

    // ---- Spike: the singleton that owns the tokio runtime ------------------
    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qml_singleton]
        #[qproperty(i32, counter, READ, NOTIFY)]
        #[qproperty(QString, state, READ, NOTIFY)]
        type Spike = super::SpikeRust;
    }

    unsafe extern "RustQt" {
        /// Writes one line into the Unix socket that the tokio task reads.
        #[qinvokable]
        fn feed(self: &Spike, line: &QString) -> bool;

        /// Routes peer lines from the tokio task to this model.
        #[qinvokable]
        unsafe fn attach(self: Pin<&mut Spike>, model: *mut PeerModel);

        /// Process-wide diagnostics; the plugin library outlives each engine.
        #[qinvokable]
        #[cxx_name = "lateCallbacks"]
        fn late_callbacks(self: &Spike) -> i32;
        #[qinvokable]
        #[cxx_name = "liveRuntimes"]
        fn live_runtimes(self: &Spike) -> i32;
        #[qinvokable]
        #[cxx_name = "droppedCallbacks"]
        fn dropped_callbacks(self: &Spike) -> i32;
        #[qinvokable]
        #[cxx_name = "attemptedCallbacks"]
        fn attempted_callbacks(self: &Spike) -> i32;
        #[qinvokable]
        #[cxx_name = "refusedCallbacks"]
        fn refused_callbacks(self: &Spike) -> i32;
        #[qinvokable]
        #[cxx_name = "createdRuntimes"]
        fn created_runtimes(self: &Spike) -> i32;
        #[qinvokable]
        #[cxx_name = "tokioThreads"]
        fn tokio_threads(self: &Spike) -> i32;
        #[qinvokable]
        #[cxx_name = "threadCount"]
        fn thread_count(self: &Spike) -> i32;
        #[qinvokable]
        #[cxx_name = "ranCallbacks"]
        fn ran_callbacks(self: &Spike) -> i32;
    }

    impl cxx_qt::Threading for Spike {}
    impl cxx_qt::Initialize for Spike {}

    // ---- Contract: the #286 TailscaleBackend contract's Qt features --------
    unsafe extern "C++" {
        include!("cxx-qt-lib/qdatetime.h");
        type QDateTime = cxx_qt_lib::QDateTime;
        include!("cxx-qt-lib/qstringlist.h");
        type QStringList = cxx_qt_lib::QStringList;
    }

    /// 7b: a Q_ENUM on the singleton (`enum class State` inside ContractObject).
    #[qenum(ContractObject)]
    enum State {
        NoState,
        NeedsMachineAuth,
        NeedsLogin,
        Stopped,
        Starting,
        Running,
    }

    unsafe extern "RustQt" {
        /// 7a: the Rust type is ContractObject; QML sees the singleton `Contract`
        /// (generates QML_NAMED_ELEMENT(Contract) + QML_SINGLETON).
        #[qobject]
        #[qml_element = "Contract"]
        #[qml_singleton]
        // 7b: an enum-typed property with NOTIFY.
        #[qproperty(State, state, READ, NOTIFY)]
        // 7d: QDateTime and QStringList property types.
        #[qproperty(QDateTime, key_expiry, cxx_name = "keyExpiry", READ, NOTIFY)]
        // 7e: two properties, ONE notify signal (declared below with #[qsignal]).
        #[qproperty(QStringList, issues, READ, NOTIFY = issues_changed)]
        #[qproperty(i32, issue_count, cxx_name = "issueCount", READ = issue_count, NOTIFY = issues_changed)]
        // 7e: a derived property with its own signal, emitted off two inputs.
        #[qproperty(bool, exit_node_active, cxx_name = "exitNodeActive", READ, NOTIFY)]
        #[qproperty(bool, exit_node_online, cxx_name = "exitNodeOnline", READ, NOTIFY)]
        #[qproperty(bool, exit_node_blocked, cxx_name = "exitNodeBlocked", READ = exit_node_blocked, NOTIFY = exit_node_blocked_changed)]
        // 7c: models the singleton owns, exposed as CONSTANT pointers.
        #[qproperty(*mut PeerModel, peers, READ = peers_model, CONSTANT)]
        #[qproperty(*mut PeerModel, exit_nodes, cxx_name = "exitNodes", READ = exit_nodes_model, CONSTANT)]
        // 7f: which backend the singleton delegates to.
        #[qproperty(QString, backend, READ, CONSTANT)]
        // Test hook: bumped after every applied snapshot, emitted last.
        #[qproperty(i32, revision, READ, NOTIFY)]
        type ContractObject = super::ContractRust;
    }

    unsafe extern "RustQt" {
        #[qsignal]
        #[cxx_name = "issuesChanged"]
        fn issues_changed(self: Pin<&mut ContractObject>);

        #[qsignal]
        #[cxx_name = "exitNodeBlockedChanged"]
        fn exit_node_blocked_changed(self: Pin<&mut ContractObject>);

        #[cxx_name = "readIssueCount"]
        fn issue_count(self: &ContractObject) -> i32;

        #[cxx_name = "readExitNodeBlocked"]
        fn exit_node_blocked(self: &ContractObject) -> bool;

        #[cxx_name = "readPeers"]
        fn peers_model(self: &ContractObject) -> *mut PeerModel;

        #[cxx_name = "readExitNodes"]
        fn exit_nodes_model(self: &ContractObject) -> *mut PeerModel;

        /// A request: hands one snapshot line to the selected backend.
        #[qinvokable]
        fn feed(self: &ContractObject, line: &QString) -> bool;

        /// Threads named backend::THREAD_NAME in this process.
        #[qinvokable]
        #[cxx_name = "backendThreads"]
        fn backend_threads(self: &ContractObject) -> i32;

        /// Process-wide PeerModel counts (the library outlives each engine).
        #[qinvokable]
        #[cxx_name = "liveModels"]
        fn live_models(self: &ContractObject) -> i32;
        #[qinvokable]
        #[cxx_name = "createdModels"]
        fn created_models(self: &ContractObject) -> i32;

        /// True when both models' QObject parent is this singleton.
        #[qinvokable]
        #[cxx_name = "modelsParentedToSelf"]
        fn models_parented_to_self(self: &ContractObject) -> bool;
    }

    impl cxx_qt::Threading for ContractObject {}
    impl cxx_qt::Initialize for ContractObject {}

    // Creates a PeerModel from Rust through cxx-qt-lib's own
    // `template <typename T> std::unique_ptr<T> rust::cxxqtlib1::make_unique()`
    // (the way cxx-qt-lib creates a QPainter). No hand-written C++.
    #[namespace = "rust::cxxqtlib1"]
    unsafe extern "C++" {
        include!("cxx-qt-lib/common.h");
        #[rust_name = "peer_model_new"]
        fn make_unique() -> UniquePtr<PeerModel>;
    }
}

pub use crate::contract::ContractRust;
pub use crate::peer_model::PeerModelRust;
pub use crate::spike::SpikeRust;
