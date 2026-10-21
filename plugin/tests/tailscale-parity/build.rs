use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    // A static QML module linked into each test binary; main() registers it
    // with cxx_qt::init_qml_module!("C7Harness"), through
    // tailscale_parity::headless_app().
    CxxQtBuilder::new_qml_module(QmlModule::new("C7Harness").version(1, 0)).files(["src/probe.rs"]).build();
}
