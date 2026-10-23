//! A scratch directory, and a C++ tree in it that `clang-query` can read
//! through a `compile_commands.json`.

use std::fs;
use std::path::{Path, PathBuf};

pub struct Dir(pub PathBuf);

impl Dir {
    pub fn new(name: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("mutate-cpp-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        Dir(p)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Writes each `(path, text)` under `tree`, and in `build` a compile
/// database with an entry for every `.cpp` among them.
pub fn project(tree: &Path, build: &Path, files: &[(&str, &str)]) {
    let mut entries = Vec::new();
    for (path, text) in files {
        let file = tree.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, text).unwrap();
        if path.ends_with(".cpp") {
            entries.push(serde_json::json!({
                "directory": tree,
                "file": file,
                "arguments": ["clang++", "-std=c++17", "-c", file],
            }));
        }
    }
    fs::create_dir_all(build).unwrap();
    fs::write(build.join("compile_commands.json"), serde_json::to_string(&entries).unwrap()).unwrap();
}

/// One of each kind: a comparison and a logical operator, an integer, a
/// bool and a call as a statement.
pub const UNIT: &str = "void g();\nint f(int a) {\n    if (a == 1 && true) {\n        g();\n    }\n    return 0;\n}\n";
