//! The view test bodies, each named by the header that runs it.

mod bar;
mod panel;

use super::Body;

/// Every body, by name.
pub const ALL: &[(&str, Body)] = &[
    ("qml_01_no_slot", bar::qml_01_no_slot),
    ("qml_02_dimmed_slot", bar::qml_02_dimmed_slot),
    ("qml_03_blocked_badge_survives", bar::qml_03_blocked_badge_survives),
    ("qml_04_label_capped", bar::qml_04_label_capped),
    ("ui_15_six_readings", bar::ui_15_six_readings),
    ("conn_15_clean_end_dimmed", bar::conn_15_clean_end_dimmed),
    ("watch_13_unknown_state_dimmed", bar::watch_13_unknown_state_dimmed),
    ("qml_05_nothing_last_known", panel::qml_05_nothing_last_known),
    ("qml_06_key_expiry", panel::qml_06_key_expiry),
    ("qml_07_health_issues", panel::qml_07_health_issues),
    ("qml_08_blocked_alert", panel::qml_08_blocked_alert),
    ("qml_23_identity_rows", panel::qml_23_identity_rows),
    ("ui_16_one_explanation", panel::ui_16_one_explanation),
];
