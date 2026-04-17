//! Subscription → Clash YAML converter.
//!
//! Accepts three input shapes:
//!   1. Clash YAML with a `proxies:` key — passed through after a Yams
//!      round-trip (fail fast on invalid YAML).
//!   2. A base64-encoded v2rayN URI list (one URI per line, newlines preserved
//!      after decoding).
//!   3. A plain-text URI list (already newline-separated).
//!
//! Supported URI schemes: `ss://`, `trojan://`, `vless://`, `vmess://`. Others
//! are skipped with a log message — upstream mihomo-rust has no URI parser, so
//! this is a focused port of the subset meow profiles rely on. Unknown schemes
//! are intentionally ignored rather than aborting the whole conversion so a
//! mixed subscription still produces a usable profile.
use anyhow::{anyhow, Result};
use base64::engine::general_purpose::STANDARD_NO_PAD;
use base64::Engine;
use serde_yaml::{Mapping, Value};
use tracing::warn;
use url::Url;

pub fn convert(body: &[u8]) -> Result<String> {
    let text = std::str::from_utf8(body)
        .map_err(|_| anyhow!("subscription body is not UTF-8"))?
        .trim();

    if looks_like_clash_yaml(text) {
        let _: serde_yaml::Value = serde_yaml::from_str(text)
            .map_err(|e| anyhow!("invalid Clash YAML: {}", e))?;
        return Ok(text.to_string());
    }

    let decoded = try_base64(text).unwrap_or_else(|| text.to_string());
    let proxies: Vec<Value> = decoded
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .filter_map(parse_uri)
        .collect();

    if proxies.is_empty() {
        return Err(anyhow!("no supported proxy URIs found in subscription"));
    }

    let names: Vec<Value> = proxies
        .iter()
        .filter_map(|p| p.as_mapping()?.get("name").cloned())
        .collect();

    let mut root = Mapping::new();
    root.insert(Value::from("proxies"), Value::from(proxies));
    root.insert(
        Value::from("proxy-groups"),
        Value::from(vec![proxy_group("Proxy", "select", names.clone())]),
    );
    root.insert(
        Value::from("rules"),
        Value::from(vec![Value::from("MATCH,Proxy")]),
    );

    serde_yaml::to_string(&Value::from(root)).map_err(|e| anyhow!("emit YAML: {}", e))
}

fn looks_like_clash_yaml(text: &str) -> bool {
    let prefix: String = text.chars().take(4096).collect();
    prefix.contains("proxies:") || prefix.contains("proxy-groups:")
}

fn try_base64(text: &str) -> Option<String> {
    // v2rayN wraps the URI list in standard base64 (with or without padding),
    // sometimes with embedded whitespace. Strip the whitespace first.
    let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    let bytes = STANDARD_NO_PAD.decode(compact.trim_end_matches('=')).ok()?;
    let decoded = String::from_utf8(bytes).ok()?;
    if decoded.contains("://") {
        Some(decoded)
    } else {
        None
    }
}

fn parse_uri(raw: &str) -> Option<Value> {
    if let Some(rest) = raw.strip_prefix("ss://") {
        parse_ss(rest)
    } else if let Some(rest) = raw.strip_prefix("trojan://") {
        parse_generic("trojan", rest)
    } else if let Some(rest) = raw.strip_prefix("vless://") {
        parse_generic("vless", rest)
    } else if let Some(rest) = raw.strip_prefix("vmess://") {
        parse_vmess(rest)
    } else {
        warn!("unsupported proxy URI scheme: {}", raw.split_once("://").map(|(s, _)| s).unwrap_or(raw));
        None
    }
}

/// ss://BASE64(method:password)@host:port#name
/// or ss://method:password@host:port#name (SIP002 without base64 userinfo)
fn parse_ss(rest: &str) -> Option<Value> {
    let (body, name) = split_fragment(rest);
    let parsed = format!("ss://{}", body);
    let url = Url::parse(&parsed).ok()?;
    let host = url.host_str()?.to_string();
    let port = url.port()?;
    let (method, password) = if url.username().is_empty() {
        return None;
    } else if url.password().is_some() {
        (url.username().to_string(), url.password().unwrap().to_string())
    } else {
        // Userinfo is base64(method:password).
        let bytes = STANDARD_NO_PAD
            .decode(url.username().trim_end_matches('='))
            .ok()?;
        let decoded = String::from_utf8(bytes).ok()?;
        let (m, p) = decoded.split_once(':')?;
        (m.to_string(), p.to_string())
    };

    let mut m = Mapping::new();
    m.insert("name".into(), name.unwrap_or_else(|| default_name("ss", &host, port)).into());
    m.insert("type".into(), "ss".into());
    m.insert("server".into(), host.into());
    m.insert("port".into(), (port as u64).into());
    m.insert("cipher".into(), method.into());
    m.insert("password".into(), password.into());
    Some(Value::from(m))
}

/// trojan/vless both follow: scheme://uuid-or-password@host:port?query#name
fn parse_generic(kind: &str, rest: &str) -> Option<Value> {
    let (body, name) = split_fragment(rest);
    let url = Url::parse(&format!("{}://{}", kind, body)).ok()?;
    let host = url.host_str()?.to_string();
    let port = url.port()?;
    let cred = url.username();
    if cred.is_empty() {
        return None;
    }

    let mut m = Mapping::new();
    m.insert("name".into(), name.unwrap_or_else(|| default_name(kind, &host, port)).into());
    m.insert("type".into(), kind.into());
    m.insert("server".into(), host.into());
    m.insert("port".into(), (port as u64).into());
    match kind {
        "trojan" => {
            m.insert("password".into(), cred.to_string().into());
        }
        "vless" => {
            m.insert("uuid".into(), cred.to_string().into());
            for (k, v) in url.query_pairs() {
                match k.as_ref() {
                    "flow" => {
                        m.insert("flow".into(), v.into_owned().into());
                    }
                    "security" if v == "tls" || v == "reality" => {
                        m.insert("tls".into(), true.into());
                    }
                    "sni" => {
                        m.insert("servername".into(), v.into_owned().into());
                    }
                    "type" => {
                        m.insert("network".into(), v.into_owned().into());
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    Some(Value::from(m))
}

/// vmess://BASE64(JSON)
fn parse_vmess(rest: &str) -> Option<Value> {
    let bytes = STANDARD_NO_PAD.decode(rest.trim_end_matches('=')).ok()?;
    let json: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let obj = json.as_object()?;
    let host = obj.get("add")?.as_str()?.to_string();
    let port: u64 = obj
        .get("port")
        .and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok()))?;
    let uuid = obj.get("id")?.as_str()?.to_string();
    let name = obj
        .get("ps")
        .and_then(|v| v.as_str())
        .map(String::from)
        .unwrap_or_else(|| default_name("vmess", &host, port as u16));
    let mut m = Mapping::new();
    m.insert("name".into(), name.into());
    m.insert("type".into(), "vmess".into());
    m.insert("server".into(), host.into());
    m.insert("port".into(), port.into());
    m.insert("uuid".into(), uuid.into());
    if let Some(aid) = obj.get("aid").and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok())) {
        m.insert("alterId".into(), aid.into());
    }
    if let Some(cipher) = obj.get("scy").and_then(|v| v.as_str()) {
        m.insert("cipher".into(), cipher.to_string().into());
    }
    if obj.get("tls").and_then(|v| v.as_str()) == Some("tls") {
        m.insert("tls".into(), true.into());
    }
    Some(Value::from(m))
}

fn split_fragment(s: &str) -> (&str, Option<String>) {
    match s.split_once('#') {
        Some((body, frag)) => (body, Some(urlencoding::decode(frag).map(|c| c.into_owned()).unwrap_or_else(|_| frag.to_string()))),
        None => (s, None),
    }
}

fn default_name(kind: &str, host: &str, port: u16) -> String {
    format!("{}-{}-{}", kind, host, port)
}

fn proxy_group(name: &str, kind: &str, proxies: Vec<Value>) -> Value {
    let mut m = Mapping::new();
    m.insert("name".into(), name.into());
    m.insert("type".into(), kind.into());
    m.insert("proxies".into(), Value::from(proxies));
    Value::from(m)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clash_yaml_passthrough() {
        let body = b"proxies:\n  - name: n1\n    type: ss\n    server: 1.2.3.4\n    port: 443\n    cipher: aes-256-gcm\n    password: p\n";
        let out = convert(body).unwrap();
        assert!(out.contains("proxies:"));
    }

    #[test]
    fn trojan_uri() {
        let uri = b"trojan://pw@example.com:443?sni=foo#My%20Node";
        let out = convert(uri).unwrap();
        assert!(out.contains("type: trojan"));
        assert!(out.contains("My Node"));
    }

    #[test]
    fn base64_wrapped_ss() {
        let raw = "ss://YWVzLTI1Ni1nY206cGFzcw@1.2.3.4:8388#n1";
        let wrapped = base64::engine::general_purpose::STANDARD.encode(raw);
        let out = convert(wrapped.as_bytes()).unwrap();
        assert!(out.contains("type: ss"));
        assert!(out.contains("cipher: aes-256-gcm"));
    }
}
