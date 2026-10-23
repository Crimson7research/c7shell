//! The view test bodies, each named by the header that runs it.

mod bar;
mod devices;
mod exit;
mod panel;
mod writes;

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
    ("qml_09_device_list", devices::qml_09_device_list),
    ("qml_10_copying", devices::qml_10_copying),
    ("qml_12_sub_cards", devices::qml_12_sub_cards),
    ("qml_13_device_search", devices::qml_13_device_search),
    ("qml_14_long_lists", devices::qml_14_long_lists),
    ("group_06_delegates_survive", devices::group_06_delegates_survive),
    ("qml_11_exit_list", exit::qml_11_exit_list),
    ("qml_17_rows_request_by_id", exit::qml_17_rows_request_by_id),
    ("qml_18_lan_switch", exit::qml_18_lan_switch),
    ("qml_19_exit_search", exit::qml_19_exit_search),
    ("qml_20_dead_after_a_refusal", writes::qml_20_dead_after_a_refusal),
    ("qml_21_settings", writes::qml_21_settings),
    ("qml_22_connect_toggle", writes::qml_22_connect_toggle),
    ("write_09_toggle_after_disconnect", writes::write_09_toggle_after_disconnect),
];
