//! The Tailscale parity harness: loads a `C7` module headless through QML,
//! points it at the in-process fake tailscaled, and runs scenarios.
//!
//! No sleeps: every wait is a loop of non-blocking `processEvents()` calls,
//! capped at [`max_iterations`], the pattern the cxx-qt spike (#288) proved.

pub mod child;
pub mod contract;
pub mod implementation;
pub mod probe;
pub mod runner;

use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;

use cxx::UniquePtr;
use cxx_qt::casting::Upcast;
use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QQmlEngine, QString, QUrl};

/// The default cap on event-loop iterations for one wait.
pub const MAX_ITERATIONS: u64 = 50_000_000;

/// The cap on event-loop iterations for one wait: [`MAX_ITERATIONS`], or
/// `C7_HARNESS_MAX_ITERATIONS` for the self-tests of a wait never reached.
pub fn max_iterations() -> u64 {
    std::env::var("C7_HARNESS_MAX_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(MAX_ITERATIONS)
}

/// Registers `C7Harness` and creates the application, headless. Call it
/// first in a child's main, before any thread exists.
pub fn headless_app() -> UniquePtr<QGuiApplication> {
    cxx_qt::init_qml_module!("C7Harness");
    // SAFETY: called first in the child's main(), before any other thread.
    unsafe {
        std::env::set_var("QT_QPA_PLATFORM", "offscreen");
        std::env::set_var("QT_FORCE_STDERR_LOGGING", "1");
        // Only the import path the harness adds may provide C7.
        std::env::remove_var("QML_IMPORT_PATH");
        std::env::remove_var("QML2_IMPORT_PATH");
    }
    QGuiApplication::new()
}

/// Pumps the event loop until `f` returns Some, at most
/// [`max_iterations`] times.
pub fn wait_until<T>(app: &QGuiApplication, mut f: impl FnMut() -> Option<T>) -> Option<T> {
    for _ in 0..max_iterations() {
        if let Some(v) = f() {
            return Some(v);
        }
        app.process_events();
        std::thread::yield_now();
    }
    None
}

/// Pumps the event loop `n` times.
pub fn pump(app: &QGuiApplication, n: u32) {
    for _ in 0..n {
        app.process_events();
    }
}

/// A file under this crate's `qml/`.
pub fn qml_file(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("qml").join(name)
}

/// A loaded engine. Dropping it destroys the singletons it created.
pub struct Loaded {
    pub engine: UniquePtr<QQmlApplicationEngine>,
    exit_code: Arc<AtomicI32>,
}

impl Loaded {
    /// The code QML passed to `Qt.exit`, if it has called it.
    pub fn exit_code(&self) -> Option<i32> {
        let c = self.exit_code.load(Ordering::SeqCst);
        (c != i32::MIN).then_some(c)
    }
}

/// Loads `qml/driver.qml` with `qml_dir` as the only added import path, and
/// waits until the driver reports ready.
pub fn load_driver(app: &QGuiApplication, qml_dir: &Path) -> Result<Loaded, String> {
    load(app, qml_dir, &qml_file("driver.qml"))
}

/// Loads `qml` with `qml_dir` as the only added import path, and waits
/// until the `Probe` reports ready.
pub fn load(app: &QGuiApplication, qml_dir: &Path, qml: &Path) -> Result<Loaded, String> {
    let mut engine = QQmlApplicationEngine::new();
    engine.pin_mut().add_import_path(&QString::from(qml_dir.to_str().ok_or("a non-UTF-8 module path")?));
    let exit_code = Arc::new(AtomicI32::new(i32::MIN));
    let failed = Arc::new(AtomicBool::new(false));
    {
        let exit_code = exit_code.clone();
        let base: Pin<&mut QQmlEngine> = engine.pin_mut().upcast_pin();
        base.on_exit(move |_, code| exit_code.store(code, Ordering::SeqCst)).release();
    }
    {
        let failed = failed.clone();
        engine.pin_mut().on_object_creation_failed(move |_, _| failed.store(true, Ordering::SeqCst)).release();
    }
    engine.pin_mut().load(&QUrl::from_local_file(&QString::from(qml.to_str().ok_or("a non-UTF-8 QML path")?)));
    let loaded = Loaded { engine, exit_code };
    let ready = wait_until(app, || {
        if failed.load(Ordering::SeqCst) {
            Some(Err(format!("{} did not load (see the QML errors above)", qml.display())))
        } else if let Some(why) = probe::failure() {
            Some(Err(format!("{} failed to start: {why}", qml.display())))
        } else if let Some(code) = loaded.exit_code() {
            Some(Err(format!("{} called Qt.exit({code}) before it was ready", qml.display())))
        } else {
            probe::is_ready().then_some(Ok(()))
        }
    });
    match ready {
        Some(Ok(())) => Ok(loaded),
        Some(Err(e)) => Err(e),
        None => Err(format!("{} never reported ready", qml.display())),
    }
}
