//! Child processes: each check and each scenario runs in a respawned copy
//! of the test binary, with a cleared environment pointed into a private
//! root, so a singleton that reads `TS_SOCKET` at construction is fresh and
//! nothing reaches the host.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

/// The variables a child inherits, `*` matching a prefix. The list of
/// `plugin/lib/testing/testmain.cpp`'s `isolationKeeps()`, plus what Rust
/// coverage and backtraces need.
pub const KEEPS: &[&str] = &[
    "LANG",
    "LANGUAGE",
    "LC_*",
    "TERM",
    "QT_LOGGING_RULES",
    "QT_MESSAGE_PATTERN",
    "QT_FORCE_STDERR_LOGGING",
    "QTEST_*",
    "LLVM_PROFILE_FILE",
    "GCOV_*",
    "ASAN_*",
    "UBSAN_*",
    "LSAN_*",
    "TSAN_*",
    "CARGO_LLVM_COV*",
    "RUST_BACKTRACE",
    "C7_HARNESS_MAX_ITERATIONS",
];

/// The variables a child gets pointed into its private root, and where.
pub const PRIVATE: &[(&str, &str)] = &[
    ("HOME", "home"),
    ("XDG_RUNTIME_DIR", "runtime"),
    ("XDG_CONFIG_HOME", "config"),
    ("XDG_DATA_HOME", "data"),
    ("XDG_CACHE_HOME", "cache"),
    ("XDG_STATE_HOME", "state"),
    ("XDG_CONFIG_DIRS", "config-dirs"),
    ("XDG_DATA_DIRS", "data-dirs"),
    ("TMPDIR", "tmp"),
    // Empty: a bare program name finds nothing.
    ("PATH", "bin"),
];

/// Whether `name` is inherited.
pub fn kept(name: &str) -> bool {
    KEEPS.iter().any(|k| match k.strip_suffix('*') {
        Some(prefix) => name.starts_with(prefix),
        None => name == *k,
    })
}

/// A private directory (mode 0700) under the temporary directory, removed
/// when dropped. Its name is short, for the 108-byte `sun_path` limit.
pub struct PrivateRoot {
    path: PathBuf,
}

impl PrivateRoot {
    pub fn new() -> PrivateRoot {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!("tsp-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir(&path).expect("create the private root");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).expect("make it private");
        PrivateRoot { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Default for PrivateRoot {
    fn default() -> PrivateRoot {
        PrivateRoot::new()
    }
}

impl Drop for PrivateRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// This test binary again, with `args`, a cleared environment (the keep
/// list, the private variables under `root`, dead buses, the offscreen
/// platform, the UTC time zone) and then `extra`.
pub fn isolated(args: &[&str], root: &PrivateRoot, extra: &[(&str, &str)]) -> Command {
    let mut cmd = Command::new(std::env::current_exe().expect("the test binary's path"));
    cmd.args(args).env_clear();
    for (name, value) in std::env::vars_os() {
        if name.to_str().is_some_and(kept) {
            cmd.env(name, value);
        }
    }
    for (var, sub) in PRIVATE {
        let dir = root.path().join(sub);
        fs::create_dir_all(&dir).expect("create a private directory");
        cmd.env(var, dir);
    }
    let dead = format!("unix:path={}/no-such-bus", root.path().display());
    cmd.env("DBUS_SESSION_BUS_ADDRESS", &dead).env("DBUS_SYSTEM_BUS_ADDRESS", &dead);
    cmd.env("QT_QPA_PLATFORM", "offscreen").env("QT_FORCE_STDERR_LOGGING", "1");
    // Not the host's /etc/localtime: a local time read from a date-time
    // without a zone is then the same instant on every host.
    cmd.env("TZ", "UTC");
    for (k, v) in extra {
        cmd.env(k, v);
    }
    cmd
}

/// The `--child=NAME` argument this process was respawned with.
pub fn child_arg() -> Option<String> {
    std::env::args().find_map(|a| a.strip_prefix("--child=").map(str::to_string))
}
