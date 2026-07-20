//! Build-time tool: download V2Ray-format `geosite.dat` (MetaCubeX) and emit a
//! meow-rs-format `geosite.mrs` for bundling in the iOS app.
//!
//! Why this exists: meow-rs only loads `.mrs` for geosite (the parser returns
//! `WrongFormat` on `.dat`), and MetaCubeX does not publish an aggregated
//! `geosite.mrs` — they ship per-category files on the `meta` branch for use
//! as individual rule-providers. The single-file format meow-rs's discovery
//! path expects has no public source, so we generate it locally from the
//! `.dat` protobuf and check the result into the app bundle.
//!
//! Format conversion (V2Ray `Domain.type` → meow-rs `DomainTrie` syntax):
//!   * `Full = 3`   → `value`         (exact-match leaf)
//!   * `Domain = 2` → `+.value`       (subdomain wildcard)
//!   * `Plain = 0`  → skipped         (substring match — trie has no equivalent)
//!   * `Regex = 1`  → skipped         (regex — trie has no equivalent)
//!
//! The `gfw` category is additionally UNIONed with the canonical gfwlist
//! (<https://github.com/gfwlist/gfwlist>) so the app's ChinaDNS-style
//! `geosite:gfw` DNS policy resolves the full censored set through the
//! tunnel — MetaCubeX's `gfw` category alone is a curated subset. See
//! [`parse_gfwlist`] for the AutoProxy→domain conversion.
//!
//! Default invocation writes to `App/Resources/GeoData/geosite.mrs` relative
//! to the repo root (assumes the binary is run from `core/rust/`).

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine;
use meow_rules::mrs_parser::{write_geosite_mrs, GeositePayload};
use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::Read;
use std::path::PathBuf;

const SOURCE_URL: &str =
    "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat";

/// Canonical gfwlist (base64 AutoProxy list). Merged into the `gfw` category.
const GFWLIST_URL: &str = "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt";

/// The geosite category the app's DNS `nameserver-policy` keys on.
const GFW_CATEGORY: &str = "gfw";

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    let out_path = args
        .get(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("App/Resources/GeoData/geosite.mrs"));

    eprintln!("==> fetching {SOURCE_URL}");
    let dat = fetch(SOURCE_URL).context("downloading geosite.dat")?;
    eprintln!("    {} bytes", dat.len());

    eprintln!("==> parsing V2Ray geosite.dat");
    let mut payload = parse_v2ray_geosite(&dat).context("parsing geosite.dat")?;
    let total_domains: usize = payload.categories.iter().map(|(_, d)| d.len()).sum();
    eprintln!(
        "    {} categories, {} domains (after Plain/Regex skip)",
        payload.categories.len(),
        total_domains,
    );

    eprintln!("==> fetching {GFWLIST_URL}");
    let gfwlist_raw = fetch(GFWLIST_URL).context("downloading gfwlist.txt")?;
    let (gfw_domains, gfw_whitelist) =
        parse_gfwlist(&gfwlist_raw).context("parsing gfwlist.txt")?;
    eprintln!(
        "    {} block domains, {} whitelist exceptions",
        gfw_domains.len(),
        gfw_whitelist.len(),
    );
    let added = merge_into_gfw(&mut payload, &gfw_domains, &gfw_whitelist);
    eprintln!(
        "==> merged gfwlist into '{GFW_CATEGORY}': +{added} net-new domains (union, whitelist-excluded)"
    );

    eprintln!("==> encoding meow-rs geosite.mrs");
    let mrs = write_geosite_mrs(&payload).map_err(|e| anyhow!("encode mrs: {e:?}"))?;
    eprintln!("    {} bytes", mrs.len());

    if let Some(parent) = out_path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }
    fs::write(&out_path, &mrs).with_context(|| format!("writing {}", out_path.display()))?;
    eprintln!("==> wrote {}", out_path.display());

    Ok(())
}

fn fetch(url: &str) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    ureq::get(url)
        .call()?
        .into_reader()
        .take(64 * 1024 * 1024) // 64 MiB cap — geosite.dat is ~6 MiB today
        .read_to_end(&mut buf)?;
    Ok(buf)
}

// --- Minimal V2Ray protobuf decoder --------------------------------------
//
// We don't pull `prost` for this; the schema is two messages with three
// fields total. The wire format is well documented:
//   * tag = (field << 3) | wire_type
//   * wire_type 0 = varint, wire_type 2 = length-delimited
//
// Schema (subset we care about):
//   message Domain   { Type type = 1; string value = 2; }   // enum Type: Plain=0 Regex=1 Domain=2 Full=3
//   message GeoSite  { string country_code = 1; repeated Domain domain = 2; }
//   message GeoSiteList { repeated GeoSite entry = 1; }
//
// `attribute` (Domain field 3) and other tags are skipped via `skip_field`.

struct ProtoReader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> ProtoReader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn eof(&self) -> bool {
        self.pos >= self.buf.len()
    }

    fn read_varint(&mut self) -> Result<u64> {
        let mut result: u64 = 0;
        let mut shift = 0;
        loop {
            if self.pos >= self.buf.len() {
                bail!("varint: unexpected EOF at {}", self.pos);
            }
            let b = self.buf[self.pos];
            self.pos += 1;
            result |= u64::from(b & 0x7f) << shift;
            if b & 0x80 == 0 {
                return Ok(result);
            }
            shift += 7;
            if shift >= 64 {
                bail!("varint: overflow at {}", self.pos);
            }
        }
    }

    fn read_len_delimited(&mut self) -> Result<&'a [u8]> {
        let len = self.read_varint()? as usize;
        if self.pos + len > self.buf.len() {
            bail!(
                "len-delimited: want {} bytes at {}, only {} remaining",
                len,
                self.pos,
                self.buf.len() - self.pos,
            );
        }
        let slice = &self.buf[self.pos..self.pos + len];
        self.pos += len;
        Ok(slice)
    }

    /// Discard a field of the given wire type whose tag was already consumed.
    fn skip_field(&mut self, wire_type: u8) -> Result<()> {
        match wire_type {
            0 => {
                let _ = self.read_varint()?;
            }
            2 => {
                let _ = self.read_len_delimited()?;
            }
            1 => {
                if self.pos + 8 > self.buf.len() {
                    bail!("skip fixed64: short read");
                }
                self.pos += 8;
            }
            5 => {
                if self.pos + 4 > self.buf.len() {
                    bail!("skip fixed32: short read");
                }
                self.pos += 4;
            }
            other => bail!("unsupported wire type {other}"),
        }
        Ok(())
    }
}

fn parse_v2ray_geosite(data: &[u8]) -> Result<GeositePayload> {
    let mut r = ProtoReader::new(data);
    let mut categories: Vec<(String, Vec<String>)> = Vec::new();
    let mut skipped_plain = 0usize;
    let mut skipped_regex = 0usize;

    while !r.eof() {
        let tag = r.read_varint()?;
        let field = (tag >> 3) as u32;
        let wire = (tag & 0x7) as u8;
        if field == 1 && wire == 2 {
            let entry = r.read_len_delimited()?;
            let (name, domains) =
                parse_geosite_entry(entry, &mut skipped_plain, &mut skipped_regex)?;
            if !name.is_empty() && !domains.is_empty() {
                categories.push((name, domains));
            }
        } else {
            r.skip_field(wire)?;
        }
    }

    if skipped_plain > 0 || skipped_regex > 0 {
        eprintln!(
            "    skipped {skipped_plain} Plain + {skipped_regex} Regex entries (no trie equivalent)"
        );
    }

    Ok(GeositePayload { categories })
}

fn parse_geosite_entry(
    data: &[u8],
    skipped_plain: &mut usize,
    skipped_regex: &mut usize,
) -> Result<(String, Vec<String>)> {
    let mut r = ProtoReader::new(data);
    let mut country_code = String::new();
    let mut domains: Vec<String> = Vec::new();

    while !r.eof() {
        let tag = r.read_varint()?;
        let field = (tag >> 3) as u32;
        let wire = (tag & 0x7) as u8;
        match (field, wire) {
            (1, 2) => {
                let bytes = r.read_len_delimited()?;
                country_code = std::str::from_utf8(bytes)
                    .context("country_code utf8")?
                    .to_ascii_lowercase();
            }
            (2, 2) => {
                let dom_bytes = r.read_len_delimited()?;
                if let Some(formatted) = parse_domain(dom_bytes, skipped_plain, skipped_regex)? {
                    domains.push(formatted);
                }
            }
            (_, w) => r.skip_field(w)?,
        }
    }

    Ok((country_code, domains))
}

fn parse_domain(
    data: &[u8],
    skipped_plain: &mut usize,
    skipped_regex: &mut usize,
) -> Result<Option<String>> {
    let mut r = ProtoReader::new(data);
    let mut domain_type: u64 = 0;
    let mut value = String::new();

    while !r.eof() {
        let tag = r.read_varint()?;
        let field = (tag >> 3) as u32;
        let wire = (tag & 0x7) as u8;
        match (field, wire) {
            (1, 0) => domain_type = r.read_varint()?,
            (2, 2) => {
                let bytes = r.read_len_delimited()?;
                value = std::str::from_utf8(bytes)
                    .context("domain value utf8")?
                    .to_ascii_lowercase();
            }
            (_, w) => r.skip_field(w)?,
        }
    }

    if value.is_empty() {
        return Ok(None);
    }
    Ok(match domain_type {
        0 => {
            *skipped_plain += 1;
            None
        }
        1 => {
            *skipped_regex += 1;
            None
        }
        2 => Some(format!("+.{value}")),
        3 => Some(value),
        other => bail!("unknown Domain.type {other}"),
    })
}

// --- gfwlist (AutoProxy) parsing -----------------------------------------
//
// gfwlist.txt is a base64-encoded AutoProxy/PAC list. We only extract host
// names for a DNS-domain trie; path/keyword/regex semantics have no trie
// equivalent and are dropped (same principle as V2Ray Plain/Regex above).
//
// Rule forms (after base64 decode), by observed frequency:
//   * `||host`            domain + subdomains  -> `+.host`
//   * `|http://host/...`  URL prefix           -> host of the URL
//   * `.host`             domain suffix        -> `+.host`
//   * `host` (bare)       AutoProxy keyword    -> kept only if it parses as a
//                                                 dotted hostname (no path)
//   * `@@<rule>`          whitelist exception  -> host collected into the
//                                                 exclusion set (accessed
//                                                 directly, never proxied)
//   * `/regex/`, `!comment`, `[AutoProxy…]`    dropped

/// Decode + parse gfwlist.txt into `(block_domains, whitelist)`. Both are
/// bare hostnames (no `+.` prefix yet); `block_domains` is de-duplicated and
/// sorted for a stable `.mrs` output.
fn parse_gfwlist(raw: &[u8]) -> Result<(Vec<String>, HashSet<String>)> {
    // The published file is base64 with embedded newlines; strip whitespace
    // before decoding.
    let compact: String = std::str::from_utf8(raw)
        .context("gfwlist utf8")?
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(compact.as_bytes())
        .context("gfwlist base64 decode")?;
    let text = String::from_utf8(decoded).context("gfwlist decoded utf8")?;

    let mut block: HashSet<String> = HashSet::new();
    let mut whitelist: HashSet<String> = HashSet::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('!') || line.starts_with('[') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("@@") {
            if let Some(host) = extract_autoproxy_host(rest) {
                whitelist.insert(host);
            }
        } else if let Some(host) = extract_autoproxy_host(line) {
            block.insert(host);
        }
    }

    let mut block: Vec<String> = block.into_iter().collect();
    block.sort();
    Ok((block, whitelist))
}

/// Extract a dotted hostname from a single AutoProxy rule body, or `None` for
/// regex / keyword / IP-literal / malformed rules that have no DNS-domain
/// meaning.
fn extract_autoproxy_host(rule: &str) -> Option<String> {
    let mut s = rule.trim();
    if s.is_empty() || s.starts_with('/') {
        return None; // regex rule — no trie equivalent
    }
    // Leading anchors: `||` (domain) or `|` (URL start).
    if let Some(r) = s.strip_prefix("||") {
        s = r;
    } else if let Some(r) = s.strip_prefix('|') {
        s = r;
    }
    // Scheme, if any (`http://`, `https://`).
    if let Some(idx) = s.find("://") {
        s = &s[idx + 3..];
    }
    // Optional userinfo (`user@host`) — rare, but keep the host half.
    if let Some(idx) = s.rfind('@') {
        s = &s[idx + 1..];
    }
    // `.host` suffix anchor.
    s = s.trim_start_matches('.');
    // Host runs until the first path / port / query / AutoProxy separator.
    let host: String = s
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect();
    let host = host.trim_matches('.').to_ascii_lowercase();

    if host.len() < 3 || !host.contains('.') {
        return None;
    }
    // Drop IPv4 literals — a DNS query never asks for one, and excluding them
    // keeps the trie to real hostnames.
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() == 4 && labels.iter().all(|l| l.parse::<u8>().is_ok()) {
        return None;
    }
    // A trailing single-char / all-numeric TLD is malformed for our purposes.
    if labels
        .last()
        .is_none_or(|tld| tld.len() < 2 || tld.parse::<u32>().is_ok())
    {
        return None;
    }
    Some(host)
}

/// Union the gfwlist block domains (minus the whitelist) into the `gfw`
/// category. Each host is emitted in BOTH forms the trie needs to honour the
/// AutoProxy `||host` = "apex + all subdomains" semantics:
///
/// * `host`   — exact leaf, so a bare-apex query (`anthropic.com`) matches;
/// * `+.host` — subdomain wildcard (`www.anthropic.com`).
///
/// The MetaCubeX `gfw` category ships only the `+.` form (V2Ray `Domain`),
/// so merging adds the exact-apex leaf even for hosts already present as
/// wildcards — closing the apex-match gap for the censored set. Returns the
/// count of net-new trie entries added. Creates the category if MetaCubeX
/// ever drops it.
fn merge_into_gfw(
    payload: &mut GeositePayload,
    block_domains: &[String],
    whitelist: &HashSet<String>,
) -> usize {
    let gfw = match payload
        .categories
        .iter_mut()
        .find(|(name, _)| name == GFW_CATEGORY)
    {
        Some((_, domains)) => domains,
        None => {
            payload
                .categories
                .push((GFW_CATEGORY.to_string(), Vec::new()));
            &mut payload.categories.last_mut().unwrap().1
        }
    };

    let mut existing: HashSet<String> = gfw.iter().cloned().collect();
    let mut added = 0usize;
    for host in block_domains {
        if whitelist.contains(host) {
            continue;
        }
        for entry in [host.clone(), format!("+.{host}")] {
            if existing.insert(entry.clone()) {
                gfw.push(entry);
                added += 1;
            }
        }
    }
    added
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn encode(s: &str) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD
            .encode(s)
            .into_bytes()
    }

    #[test]
    fn extract_host_handles_common_forms() {
        assert_eq!(
            extract_autoproxy_host("||example.com"),
            Some("example.com".into())
        );
        assert_eq!(
            extract_autoproxy_host("|http://sub.example.com/path?q=1"),
            Some("sub.example.com".into())
        );
        assert_eq!(
            extract_autoproxy_host(".example.com"),
            Some("example.com".into())
        );
        assert_eq!(
            extract_autoproxy_host("||example.com^"),
            Some("example.com".into())
        );
        assert_eq!(
            extract_autoproxy_host("||www.google.com/ncr"),
            Some("www.google.com".into())
        );
    }

    #[test]
    fn extract_host_rejects_non_domains() {
        assert_eq!(extract_autoproxy_host("/^https?:\\/\\/.*blogspot/"), None);
        assert_eq!(extract_autoproxy_host("|http://85.17.73.31/"), None); // IPv4
        assert_eq!(extract_autoproxy_host("localhost"), None); // no dot
        assert_eq!(extract_autoproxy_host(""), None);
        assert_eq!(extract_autoproxy_host("keyword*wild"), None); // wildcard splits host
    }

    #[test]
    fn parse_gfwlist_splits_block_and_whitelist() {
        let list = "[AutoProxy 0.2.9]\n\
             ! comment\n\
             ||blocked.example\n\
             ||also.blocked.example\n\
             |http://path.blocked.example/x\n\
             @@||white.example\n\
             /regexrule/\n";
        let (block, white) = parse_gfwlist(&encode(list)).unwrap();
        assert!(block.contains(&"blocked.example".to_string()));
        assert!(block.contains(&"also.blocked.example".to_string()));
        assert!(block.contains(&"path.blocked.example".to_string()));
        assert!(white.contains("white.example"));
        // sorted + deduped
        assert!(block.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn merge_unions_and_excludes_whitelist() {
        let mut payload = GeositePayload {
            categories: vec![
                ("gfw".to_string(), vec!["+.already.example".to_string()]),
                ("cn".to_string(), vec!["+.baidu.com".to_string()]),
            ],
        };
        let block = vec![
            "already.example".to_string(), // +.already.example exists; apex leaf is new
            "fresh.example".to_string(),
            "white.example".to_string(), // excluded by whitelist
        ];
        let white: HashSet<String> = ["white.example".to_string()].into_iter().collect();
        let added = merge_into_gfw(&mut payload, &block, &white);
        // already.example → +1 exact leaf (wildcard already present);
        // fresh.example → +2 (exact + wildcard); white.example → 0.
        assert_eq!(added, 3);
        let gfw = &payload
            .categories
            .iter()
            .find(|(n, _)| n == "gfw")
            .unwrap()
            .1;
        assert!(gfw.contains(&"already.example".to_string()));
        assert!(gfw.contains(&"fresh.example".to_string()));
        assert!(gfw.contains(&"+.fresh.example".to_string()));
        assert!(!gfw.iter().any(|d| d.contains("white.example")));
    }

    #[test]
    fn loads_back_via_geosite_db() {
        let bytes = std::fs::read("../../../App/Resources/GeoData/geosite.mrs").expect("read mrs");
        // `None` = no category filter, load everything (preserves prior behavior
        // from before `from_bytes` gained the category-filter argument).
        let db = meow_rules::geosite::GeositeDB::from_bytes(&bytes, None).expect("load mrs");
        assert!(db.category_count() > 100, "expected many categories");
    }
}
