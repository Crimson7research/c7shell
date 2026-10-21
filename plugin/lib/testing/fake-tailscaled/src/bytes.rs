//! Byte strings in JSON: a JSON string for UTF-8 bytes, `{"hex": "..."}` for
//! any bytes, and, for a body only, `{"json": value}`, serialised compactly.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

/// Bytes written in a scenario: a string (UTF-8) or `{"hex": "..."}`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Bytes(pub Vec<u8>);

/// A body: [`Bytes`], or `{"json": value}` serialised compactly.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Body(pub Vec<u8>);

impl From<&[u8]> for Bytes {
    fn from(b: &[u8]) -> Bytes {
        Bytes(b.to_vec())
    }
}

/// Decodes lowercase or uppercase hex, two digits per byte.
pub fn decode_hex(hex: &str) -> Result<Vec<u8>, String> {
    if !hex.is_ascii() {
        return Err(format!("hex {hex:?} is not hex"));
    }
    if !hex.len().is_multiple_of(2) {
        return Err(format!("hex {hex:?} has an odd number of digits"));
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).map_err(|_| format!("hex {hex:?} is not hex")))
        .collect()
}

pub fn encode_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The bytes a JSON value names, `json` allowed only when `allow_json`.
fn from_value(value: Value, allow_json: bool) -> Result<Vec<u8>, String> {
    match value {
        Value::String(s) => Ok(s.into_bytes()),
        Value::Object(map) if map.len() == 1 => {
            let (key, value) = map.into_iter().next().unwrap();
            match (key.as_str(), value) {
                ("hex", Value::String(hex)) => decode_hex(&hex),
                ("json", value) if allow_json && (value.is_object() || value.is_array()) => {
                    Ok(serde_json::to_vec(&value).expect("a JSON value serialises"))
                }
                ("json", _) if allow_json => Err("a json body must be an object or an array".into()),
                (key, _) => Err(format!("unknown byte-string form `{key}`")),
            }
        }
        other => Err(format!("expected a string or {{\"hex\": ...}}, got {other}")),
    }
}

impl<'de> Deserialize<'de> for Bytes {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Bytes, D::Error> {
        from_value(Value::deserialize(d)?, false).map(Bytes).map_err(D::Error::custom)
    }
}

impl<'de> Deserialize<'de> for Body {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Body, D::Error> {
        from_value(Value::deserialize(d)?, true).map(Body).map_err(D::Error::custom)
    }
}

/// A string when the bytes are UTF-8, else `{"hex": ...}`.
pub fn to_value(bytes: &[u8]) -> Value {
    match std::str::from_utf8(bytes) {
        Ok(s) => Value::String(s.to_string()),
        Err(_) => serde_json::json!({ "hex": encode_hex(bytes) }),
    }
}

impl Serialize for Bytes {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        to_value(&self.0).serialize(s)
    }
}

impl Serialize for Body {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        to_value(&self.0).serialize(s)
    }
}
