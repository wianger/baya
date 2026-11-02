use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

fn default_room() -> String {
    "main".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OuterEnvelope {
    pub peer: String,
    /// Destination room on the way in; the sender's room on the way out.
    /// Absent in legacy frames → "main".
    #[serde(default = "default_room")]
    pub room: String,
    /// Sender room on a connection that opened several rooms (`room_open`).
    /// Ignored unless the connection owns that room.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_room: Option<String>,
    /// Destination room, added on delivery so a multi-room connection can
    /// dispatch the frame. Old clients ignore it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to_room: Option<String>,
    /// Base64 payload; the relay never decodes it.
    pub ct: String,
}

/// Env var overriding the envelope size cap (whole MiB).
pub const MAX_CT_ENV: &str = "RELAY_MAX_CT_MIB";

/// Default cap: 4 MiB of decoded payload. Images are base64-encoded twice
/// (inner `data` and outer `ct`), so this leaves room above the app's ~1.5 MB
/// compressed image ceiling.
pub const DEFAULT_MAX_CT_MIB: usize = 4;

/// Effective envelope cap in bytes, read once from [`MAX_CT_ENV`]. A missing
/// or invalid value falls back to the default; it never panics.
pub fn max_ct_bytes() -> usize {
    static MAX_CT_BYTES: OnceLock<usize> = OnceLock::new();
    *MAX_CT_BYTES.get_or_init(|| {
        let mib = std::env::var(MAX_CT_ENV)
            .ok()
            .and_then(|s| s.trim().parse::<usize>().ok())
            .filter(|&n| n > 0)
            .unwrap_or(DEFAULT_MAX_CT_MIB);
        mib * 1024 * 1024
    })
}

#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("invalid json: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("payload too large: {0} bytes (max {1})")]
    TooLarge(usize, usize),
}

/// Parses one envelope line and checks `ct` against [`max_ct_bytes`]. `ct` is
/// never decoded; its size is estimated as 3/4 of the base64 length.
pub fn parse_line(line: &str) -> Result<OuterEnvelope, ParseError> {
    parse_line_with_max(line, max_ct_bytes())
}

/// [`parse_line`] with an injected cap, so tests avoid the memoized env var.
fn parse_line_with_max(line: &str, max_ct_bytes: usize) -> Result<OuterEnvelope, ParseError> {
    let env: OuterEnvelope = serde_json::from_str(line)?;
    let estimated = env.ct.len() * 3 / 4;
    if estimated > max_ct_bytes {
        return Err(ParseError::TooLarge(estimated, max_ct_bytes));
    }
    Ok(env)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_envelope() {
        let line = r#"{"peer":"abc","ct":"AAA="}"#;
        let env = parse_line(line).unwrap();
        assert_eq!(env.peer, "abc");
        assert_eq!(env.room, "main"); // defaults to "main" when absent
        assert_eq!(env.ct, "AAA=");
    }

    #[test]
    fn parses_envelope_with_room() {
        let line = r#"{"peer":"abc","room":"aB12CD34eF56","ct":"AAA="}"#;
        let env = parse_line(line).unwrap();
        assert_eq!(env.room, "aB12CD34eF56");
    }

    #[test]
    fn rejects_too_large() {
        // 12 MiB de "A" → estimativa 9 MiB, acima do default de 4 MiB.
        // (Antes era 2 MiB → 1,5 MiB estimado, que agora PASSARIA no default.)
        let big = "A".repeat(12 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, big);
        assert!(matches!(parse_line(&line), Err(ParseError::TooLarge(..))));
    }

    #[test]
    fn accepts_two_mb_payload_under_default() {
        // 3 MiB of base64 ≈ 2.25 MiB payload: must pass the 4 MiB default.
        let img = "A".repeat(3 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, img);
        let env = parse_line(&line).expect("≈2 MB payload must pass under 4 MiB default");
        assert_eq!(env.peer, "abc");
    }

    #[test]
    fn default_max_ct_bytes_is_four_mib() {
        // Without RELAY_MAX_CT_MIB the cap is the 4 MiB default.
        assert_eq!(max_ct_bytes(), DEFAULT_MAX_CT_MIB * 1024 * 1024);
        assert_eq!(max_ct_bytes(), 4 * 1024 * 1024);
    }

    #[test]
    fn injected_max_overrides_limit() {
        // ≈2.25 MiB payload: rejected under a 1 MiB cap, accepted under 4 MiB.
        let payload = "A".repeat(3 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, payload);

        assert!(matches!(
            parse_line_with_max(&line, 1024 * 1024),
            Err(ParseError::TooLarge(..))
        ));
        assert!(parse_line_with_max(&line, 4 * 1024 * 1024).is_ok());
    }

    #[test]
    fn rejects_invalid_json() {
        assert!(matches!(
            parse_line("not json at all"),
            Err(ParseError::InvalidJson(_))
        ));
    }
}
