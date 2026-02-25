//! Bearer token authentication middleware for the web gateway.

use axum::{
    extract::{Request, State},
    http::{HeaderMap, StatusCode, Uri},
    middleware::Next,
    response::{IntoResponse, Response},
};
use subtle::ConstantTimeEq;
use url::form_urlencoded;

/// Shared auth state injected via axum middleware state.
#[derive(Clone)]
pub struct AuthState {
    pub token: String,
}

fn allows_query_token(uri: &Uri) -> bool {
    matches!(
        uri.path(),
        "/api/chat/events" | "/api/logs/events" | "/api/chat/ws"
    )
}

/// Extract token from an Authorization header value.
fn bearer_token(value: &str) -> Option<&str> {
    value.strip_prefix("Bearer ")
}

/// Extract token query parameter from URL query string.
fn query_token(query: &str) -> Option<String> {
    form_urlencoded::parse(query.as_bytes())
        .find(|(k, _)| k == "token")
        .map(|(_, v)| v.into_owned())
}

/// Auth middleware that validates bearer token from header or query param.
///
/// SSE connections can't set headers from `EventSource`, so we accept
/// `?token=xxx` only on SSE endpoints.
pub async fn auth_middleware(
    State(auth): State<AuthState>,
    headers: HeaderMap,
    request: Request,
    next: Next,
) -> Response {
    // Try Authorization header first (constant-time comparison)
    if let Some(auth_header) = headers.get("authorization")
        && let Ok(value) = auth_header.to_str()
        && let Some(token) = bearer_token(value)
        && bool::from(token.as_bytes().ct_eq(auth.token.as_bytes()))
    {
        return next.run(request).await;
    }

    // Fall back to query parameter only for SSE EventSource endpoints.
    if allows_query_token(request.uri())
        && let Some(query) = request.uri().query()
        && let Some(token) = query_token(query)
        && bool::from(token.as_bytes().ct_eq(auth.token.as_bytes()))
    {
        return next.run(request).await;
    }

    (StatusCode::UNAUTHORIZED, "Invalid or missing auth token").into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_auth_state_clone() {
        let state = AuthState {
            token: "test-token".to_string(),
        };
        let cloned = state.clone();
        assert_eq!(cloned.token, "test-token");
    }

    #[test]
    fn test_allows_query_token() {
        let sse_chat: Uri = "/api/chat/events?token=x".parse().expect("uri");
        let sse_logs: Uri = "/api/logs/events?token=x".parse().expect("uri");
        let ws: Uri = "/api/chat/ws?token=x".parse().expect("uri");
        let non_sse: Uri = "/api/chat/history?token=x".parse().expect("uri");

        assert!(allows_query_token(&sse_chat));
        assert!(allows_query_token(&sse_logs));
        assert!(allows_query_token(&ws));
        assert!(!allows_query_token(&non_sse));
    }

    #[test]
    fn test_bearer_token_parser() {
        assert_eq!(bearer_token("Bearer abc"), Some("abc"));
        assert_eq!(bearer_token("bearer abc"), None);
        assert_eq!(bearer_token("Token abc"), None);
    }

    #[test]
    fn test_query_token_parser() {
        assert_eq!(query_token("token=abc"), Some("abc".to_string()));
        assert_eq!(query_token("x=1&token=abc&y=2"), Some("abc".to_string()));
        assert_eq!(query_token("token=a%2Bb%3Dc"), Some("a+b=c".to_string()));
        assert_eq!(query_token("x=1&y=2"), None);
    }
}
