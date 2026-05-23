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
//! Default invocation writes to `App/Resources/GeoData/geosite.mrs` relative
//! to the repo root (assumes the binary is run from `core/rust/`).

use anyhow::{anyhow, bail, Context, Result};
use meow_rules::mrs_parser::{write_geosite_mrs, GeositePayload};
use std::env;
use std::fs;
use std::io::Read;
use std::path::PathBuf;

const SOURCE_URL: &str =
    "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat";

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
    let payload = parse_v2ray_geosite(&dat).context("parsing geosite.dat")?;
    let total_domains: usize = payload.categories.iter().map(|(_, d)| d.len()).sum();
    eprintln!(
        "    {} categories, {} domains (after Plain/Regex skip)",
        payload.categories.len(),
        total_domains,
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

#[cfg(test)]
mod tests {
    #[test]
    fn loads_back_via_geosite_db() {
        let bytes = std::fs::read("../../../App/Resources/GeoData/geosite.mrs").expect("read mrs");
        let db = meow_rules::geosite::GeositeDB::from_bytes(&bytes).expect("load mrs");
        assert!(db.category_count() > 100, "expected many categories");
    }
}
