use serde_json::{Map, Value};

const REDACTED: &str = "[REDACTED]";
const SENSITIVE_EXACT: &[&str] = &[
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "api-key",
    "api_key",
    "access_token",
    "refresh_token",
    "session_token",
    "id_token",
    "token",
    "password",
    "passwd",
    "secret",
    "client_secret",
    "private_key",
    "apiKey",
    "apiSecret",
];
const SENSITIVE_SUBSTRINGS: &[&str] = &["token", "secret", "password", "credential", "auth"];

fn is_sensitive_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    if SENSITIVE_EXACT.contains(&lower.as_str()) {
        return true;
    }
    SENSITIVE_SUBSTRINGS.iter().any(|s| lower.contains(s))
}

fn redact_in_place(value: &mut Value) {
    match value {
        Value::Object(map) => redact_object(map),
        Value::Array(items) => {
            for item in items {
                redact_in_place(item);
            }
        }
        _ => {}
    }
}

fn redact_object(map: &mut Map<String, Value>) {
    for (key, val) in map {
        if is_sensitive_key(key) {
            *val = Value::String(REDACTED.to_string());
        } else {
            redact_in_place(val);
        }
    }
}

pub fn redact_sensitive_json(value: &Value) -> Value {
    let mut cloned = value.clone();
    redact_in_place(&mut cloned);
    cloned
}

#[cfg(test)]
mod tests {
    use super::redact_sensitive_json;

    #[test]
    fn redacts_exact_sensitive_keys() {
        let input = serde_json::json!({
            "headers": {
                "Authorization": "Bearer abc",
                "x-api-key": "k-123",
                "content-type": "application/json"
            },
            "password": "p@ss"
        });
        let out = redact_sensitive_json(&input);
        assert_eq!(out["headers"]["Authorization"], "[REDACTED]");
        assert_eq!(out["headers"]["x-api-key"], "[REDACTED]");
        assert_eq!(out["headers"]["content-type"], "application/json");
        assert_eq!(out["password"], "[REDACTED]");
    }

    #[test]
    fn redacts_nested_substring_keys() {
        let input = serde_json::json!({
            "body": {
                "clientSecret": "xyz",
                "nested": [{"authToken": "123"}, {"query": "ok"}]
            }
        });
        let out = redact_sensitive_json(&input);
        assert_eq!(out["body"]["clientSecret"], "[REDACTED]");
        assert_eq!(out["body"]["nested"][0]["authToken"], "[REDACTED]");
        assert_eq!(out["body"]["nested"][1]["query"], "ok");
    }
}
