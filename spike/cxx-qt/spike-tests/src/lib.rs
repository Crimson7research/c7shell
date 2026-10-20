//! Shared harness for the spike checks: a headless QGuiApplication, a
//! QQmlApplicationEngine that only knows the staged module directory, and a
//! bounded event-loop wait. No sleeps anywhere.

use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;

use cxx::UniquePtr;
use cxx_qt::casting::Upcast;
use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QQmlEngine, QString, QUrl};

/// Upper bound on event-loop iterations for one wait. Each iteration is a
/// non-blocking processEvents(), so this bounds the wait without a timer.
pub const MAX_ITERATIONS: u64 = 50_000_000;

/// Creates the application. QT_QPA_PLATFORM is set here, before Qt starts.
pub fn headless_app() -> UniquePtr<QGuiApplication> {
    // SAFETY: called first thing in main(), before any other thread exists.
    unsafe {
        std::env::set_var("QT_QPA_PLATFORM", "offscreen");
        std::env::set_var("QT_FORCE_STDERR_LOGGING", "1");
        // Only the import path we add may provide C7Spike.
        std::env::remove_var("QML_IMPORT_PATH");
        std::env::remove_var("QML2_IMPORT_PATH");
    }
    QGuiApplication::new()
}

pub fn workspace_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf()
}

/// The staged module root (contains C7Spike/). `cargo stage` creates it.
pub fn staged_import_path() -> PathBuf {
    let p = std::env::var_os("C7SPIKE_QML_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| workspace_dir().join("target/qml"));
    assert!(p.join("C7Spike/qmldir").is_file(), "{} has no C7Spike/qmldir; run `cargo stage` first", p.display());
    p
}

pub fn qml_file(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("qml").join(name)
}

/// What happened to one load.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// QML called Qt.exit(code).
    Exited(i32),
    /// The engine emitted objectCreationFailed (e.g. `import C7Spike` not found).
    CreationFailed,
    /// Neither happened within MAX_ITERATIONS.
    TimedOut,
}

pub struct Loaded {
    pub engine: UniquePtr<QQmlApplicationEngine>,
    pub outcome: Outcome,
}

/// Builds an engine whose only added import path is `import_path`, loads
/// `qml`, and pumps the event loop until QML exits or loading fails.
pub fn load_and_wait(app: &QGuiApplication, import_path: &Path, qml: &Path) -> Loaded {
    load_and_wait_paths(app, &[import_path], qml)
}

/// load_and_wait with several added import paths (e.g. C7Spike and C7 together).
pub fn load_and_wait_paths(app: &QGuiApplication, import_paths: &[&Path], qml: &Path) -> Loaded {
    let mut engine = QQmlApplicationEngine::new();
    for p in import_paths {
        engine.pin_mut().add_import_path(&QString::from(p.to_str().unwrap()));
    }

    let exit_code = Arc::new(AtomicI32::new(i32::MIN));
    let failed = Arc::new(AtomicBool::new(false));
    {
        let exit_code = exit_code.clone();
        let base: Pin<&mut QQmlEngine> = engine.pin_mut().upcast_pin();
        base.on_exit(move |_, code| exit_code.store(code, Ordering::SeqCst)).release();
    }
    {
        let failed = failed.clone();
        engine
            .pin_mut()
            .on_object_creation_failed(move |_, _| failed.store(true, Ordering::SeqCst))
            .release();
    }
    engine.pin_mut().load(&QUrl::from_local_file(&QString::from(qml.to_str().unwrap())));

    let outcome = wait_until(app, || {
        if failed.load(Ordering::SeqCst) {
            Some(Outcome::CreationFailed)
        } else {
            let c = exit_code.load(Ordering::SeqCst);
            (c != i32::MIN).then_some(Outcome::Exited(c))
        }
    })
    .unwrap_or(Outcome::TimedOut);
    Loaded { engine, outcome }
}

/// Pumps the event loop until `f` returns Some, at most MAX_ITERATIONS times.
pub fn wait_until<T>(app: &QGuiApplication, mut f: impl FnMut() -> Option<T>) -> Option<T> {
    for _ in 0..MAX_ITERATIONS {
        if let Some(v) = f() {
            return Some(v);
        }
        app.process_events();
        std::thread::yield_now();
    }
    None
}

/// Pumps the event loop a fixed number of times (flushes posted events).
pub fn pump(app: &QGuiApplication, n: u32) {
    for _ in 0..n {
        app.process_events();
    }
}

/// Names of this process's threads, from /proc/self/task/*/comm.
pub fn thread_names() -> Vec<String> {
    std::fs::read_dir("/proc/self/task")
        .unwrap()
        .filter_map(|e| std::fs::read_to_string(e.ok()?.path().join("comm")).ok())
        .map(|s| s.trim().to_string())
        .collect()
}

pub fn tokio_threads() -> usize {
    thread_names().iter().filter(|n| n.starts_with("c7spike-tokio")).count()
}

/// Minimal check reporter: prints `ok`/`FAIL` lines and exits non-zero on failure.
#[derive(Default)]
pub struct Report {
    failures: Vec<String>,
}

impl Report {
    pub fn check(&mut self, ok: bool, what: impl Into<String>) {
        let what = what.into();
        println!("{} {what}", if ok { "ok  " } else { "FAIL" });
        if !ok {
            self.failures.push(what);
        }
    }

    pub fn finish(self, name: &str) {
        if self.failures.is_empty() {
            println!("{name}: PASS");
        } else {
            println!("{name}: FAIL ({} failed)", self.failures.len());
            std::process::exit(1);
        }
    }
}

/// Threads of the Contract singleton's real backend (c7spike::backend::THREAD_NAME).
pub fn contract_threads() -> usize {
    thread_names().iter().filter(|n| n.starts_with("c7contract-rt")).count()
}

/// The value of `--name=value` among this process's arguments.
pub fn arg_value(name: &str) -> Option<String> {
    let prefix = format!("--{name}=");
    std::env::args().find_map(|a| a.strip_prefix(&prefix).map(str::to_string))
}

/// Runs this test binary again as a child with extra arguments and env vars
/// (None removes a var), so a choice made at process start (an env var read
/// when the singleton is constructed, or QML-visible arguments) is fresh.
/// Returns whether the child exited 0. Its output goes to this process's.
pub fn respawn(args: &[&str], env: &[(&str, Option<&str>)]) -> bool {
    let mut cmd = std::process::Command::new(std::env::current_exe().unwrap());
    cmd.args(args);
    for (k, v) in env {
        match v {
            Some(v) => cmd.env(k, v),
            None => cmd.env_remove(k),
        };
    }
    cmd.status().expect("respawn test binary").success()
}

/// Like `respawn`, but captures the child's stdout+stderr and returns them
/// with the exit status, so a test can assert on Qt's own log lines.
pub fn respawn_output(args: &[&str], env: &[(&str, &str)]) -> (bool, String) {
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args(args)
        .envs(env.iter().copied())
        .output()
        .expect("respawn test binary");
    let text = String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr);
    (out.status.success(), text)
}
