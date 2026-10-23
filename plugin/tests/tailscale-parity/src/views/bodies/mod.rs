//! The view test bodies, each named by the header that runs it.

mod bar;

use super::Body;

/// Every body, by name.
pub const ALL: &[(&str, Body)] = &[
    ("qml_01_no_slot", bar::qml_01_no_slot),
    ("qml_02_dimmed_slot", bar::qml_02_dimmed_slot),
    ("qml_03_blocked_badge_survives", bar::qml_03_blocked_badge_survives),
];
