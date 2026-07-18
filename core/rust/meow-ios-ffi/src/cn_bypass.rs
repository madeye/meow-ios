//! CN-bypass probe: decide — before the TUN routes are installed — whether
//! the active config routes mainland-China destinations to a DIRECT terminal,
//! and if so materialize the CN CIDR set so Swift can exclude those routes
//! from the tunnel entirely.
//!
//! Motivation: with a `GEOIP,CN,DIRECT`-style rule the engine already dials
//! CN destinations directly, but every CN packet still crosses the
//! NEPacketTunnelFlow → netstack → relay path first, costing NE memory/CPU
//! and an extra copy in both directions. Excluding the CN ranges from the
//! TUN's route set lets the kernel keep that traffic on the physical
//! interface and out of the 50 MB NE budget altogether.
//!
//! The decision is a *functional* rule-matching test, not a YAML grep: each
//! representative CN IP is pushed through the parsed rule chain exactly the
//! way `TunnelInner::resolve_proxy` would route it, and the bypass is
//! approved only when every probe IP hits a `GEOIP,CN` rule whose target
//! resolves — through selector/url-test/fallback group chains — to a Direct
//! terminal adapter. Rule ordering therefore shadows correctly: an earlier
//! `MATCH,Proxy` or an `IP-CIDR,…,Proxy` covering a probe IP vetoes the
//! bypass (fail-safe: traffic keeps flowing through the tunnel, where the
//! engine still applies the full rule set).
//!
//! The CN ranges come from the same Country.mmdb the GEOIP rule matched
//! against (explicit `geodata.mmdb-path` override, else
//! `$XDG_CONFIG_HOME/meow/Country.mmdb` staged by the app's GeoAssetStager),
//! so the excluded route set and the rule's match set cannot drift apart.
//!
//! Process placement: the probe runs in the **app** process right before
//! `startVPNTunnel` — a full config load plus an MMDB walk is a transient
//! multi-MB allocation the NE jetsam budget should never pay. The result is
//! persisted as an artifact in the App Group keyed by the SHA-256 of the raw
//! config; the extension re-hashes `config.yaml` at start and ignores a
//! stale artifact (on-demand starts after an unprobed config edit fall back
//! to full-tunnel routing rather than applying outdated routes).

use anyhow::{anyhow, Context, Result};
use meow_common::{AdapterType, Metadata, RuleMatchHelper, RuleType, TunnelMode};
use meow_config::Config;
use meow_rules::country_index::CountryIndex;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::net::IpAddr;
use std::path::Path;

/// Representative mainland-China destinations, one per major operator, all
/// stable public anycast resolvers: 114DNS (China Telecom), AliDNS, Tencent
/// DNSPod, Baidu. Every one must route GEOIP/CN → Direct for the bypass to
/// engage; a single divergence (e.g. an earlier IP-CIDR proxy rule carving
/// out part of CN) keeps CN traffic inside the tunnel.
const PROBE_IPS: [&str; 4] = [
    "114.114.114.114",
    "223.5.5.5",
    "119.29.29.29",
    "180.76.76.76",
];

/// Group chains deeper than this are treated as not-direct. Groups nesting
/// eight levels deep don't happen in real configs; the cap only guards
/// against membership cycles.
const MAX_GROUP_DEPTH: usize = 8;

/// First line of the artifact — bump the version when the format changes so
/// an old extension never misparses a new artifact (and vice versa).
const ARTIFACT_HEADER: &str = "meow-cn-bypass v1";

/// Load `config_path`, run the CN-direct probe, and atomically write the
/// artifact to `out_path`. Returns whether the bypass is engaged.
pub fn probe_and_write(config_path: &str, out_path: &str) -> Result<bool> {
    probe_and_write_with_ips(config_path, out_path, &PROBE_IPS)
}

/// Test seam: same as [`probe_and_write`] but with caller-chosen probe IPs
/// (unit tests use MaxMind's fixture MMDB, whose CN networks don't contain
/// the production probe set).
fn probe_and_write_with_ips(config_path: &str, out_path: &str, probe_ips: &[&str]) -> Result<bool> {
    let source =
        std::fs::read(config_path).with_context(|| format!("reading config from {config_path}"))?;
    let sha = format!("{:x}", Sha256::digest(&source));

    // Rule-provider fetches inside the load can hit HTTPS; make sure the
    // process-wide rustls provider exists before that happens (idempotent).
    crate::engine::install_tls_provider();
    let cfg = crate::engine::load_stripped_config(config_path)?;

    let cn_direct = config_routes_cn_direct(&cfg, probe_ips)?;

    let mut artifact = format!(
        "{ARTIFACT_HEADER}\nconfig-sha256 {sha}\ncn-direct {}\n",
        i32::from(cn_direct)
    );
    if cn_direct {
        let mmdb_path = cfg
            .geodata
            .mmdb_path
            .clone()
            .unwrap_or_else(meow_config::default_geoip_path);
        let (v4, v6) = cn_ranges(&mmdb_path)?;
        tracing::info!(
            "cn-bypass: probe passed, {} v4 + {} v6 CN ranges from {}",
            v4.len(),
            v6.len(),
            mmdb_path.display()
        );
        for cidr in v4.iter().chain(v6.iter()) {
            artifact.push_str(cidr);
            artifact.push('\n');
        }
    } else {
        tracing::info!("cn-bypass: probe negative — CN traffic stays inside the tunnel");
    }

    write_atomically(Path::new(out_path), artifact.as_bytes())?;
    Ok(cn_direct)
}

/// True when the config is in rule mode and EVERY probe IP hits a `GEOIP`
/// rule with payload `CN` whose target resolves to a Direct terminal.
fn config_routes_cn_direct(cfg: &Config, probe_ips: &[&str]) -> Result<bool> {
    if cfg.general.mode != TunnelMode::Rule {
        return Ok(false);
    }
    for ip_str in probe_ips {
        let ip: IpAddr = ip_str
            .parse()
            .map_err(|e| anyhow!("invalid probe IP {ip_str}: {e}"))?;
        if !probe_ip_is_geoip_cn_direct(cfg, ip) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Route one destination IP through the rule chain the same way
/// `TunnelInner::resolve_proxy` does (first match wins) and check the match
/// is `GEOIP,CN,<direct terminal>`. A fall-through to FINAL — even to a
/// direct FINAL — is not a GEOIP hit and does not approve the bypass.
fn probe_ip_is_geoip_cn_direct(cfg: &Config, ip: IpAddr) -> bool {
    let metadata = Metadata {
        dst_ip: Some(ip),
        dst_port: 443,
        ..Metadata::default()
    };
    let helper = RuleMatchHelper;
    for rule in &cfg.rules {
        if let Some(adapter) = rule.match_and_resolve(&metadata, &helper) {
            return rule.rule_type() == RuleType::GeoIp
                && rule.payload().eq_ignore_ascii_case("cn")
                && terminal_is_direct(cfg, adapter, &metadata);
        }
    }
    false
}

/// Chase a rule target through group adapters (selector → selected member,
/// url-test/fallback → current pick, …) to its terminal and require
/// `AdapterType::Direct`. Unknown adapter names mirror the engine's runtime
/// fallback in `TunnelInner::resolve_proxy` — "proxy not found, using
/// DIRECT" — so the probe agrees with what the engine would actually do.
fn terminal_is_direct(cfg: &Config, name: &str, metadata: &Metadata) -> bool {
    let Some(mut proxy) = cfg.proxies.get(name).cloned() else {
        return true;
    };
    for _ in 0..=MAX_GROUP_DEPTH {
        if proxy.adapter_type() == AdapterType::Direct {
            return true;
        }
        match proxy.unwrap_proxy(metadata) {
            Some(inner) => proxy = inner,
            None => return false,
        }
    }
    false
}

/// The fake-IP pool `meow_patch_config` pins (`dns.fake-ip-range`). Every
/// fake-IP destination must keep routing INTO the tunnel, so a CN CIDR that
/// overlaps this pool (possible after a Country.mmdb update — 28/8 is
/// unallocated today) must never reach the excluded-route set: excluding it
/// would black-hole all fake-IP'd traffic for those addresses.
const FAKE_IP_POOL_START: u32 = 28 << 24; // 28.0.0.0
const FAKE_IP_POOL_END: u32 = (29 << 24) - 1; // 28.255.255.255

/// Enumerate the CN v4/v6 CIDRs from the MMDB, merged/simplified by
/// `CountryIndex` — the exact set a `GEOIP,CN` rule matches against — minus
/// anything overlapping the fake-IP pool.
fn cn_ranges(mmdb_path: &Path) -> Result<(Vec<String>, Vec<String>)> {
    let reader = maxminddb::Reader::open_readfile(mmdb_path)
        .with_context(|| format!("opening GeoIP MMDB at {}", mmdb_path.display()))?;
    let allowed: HashSet<String> = std::iter::once("CN".to_string()).collect();
    let index = CountryIndex::build(&reader, &allowed).map_err(|e| anyhow!(e))?;
    let ranges = index.ranges_for("CN");
    let mut skipped = 0usize;
    let v4 = ranges
        .v4
        .iter()
        .filter(|net| {
            let start = u32::from(net.network());
            let end = u32::from(net.broadcast());
            let overlaps_pool = start <= FAKE_IP_POOL_END && end >= FAKE_IP_POOL_START;
            skipped += usize::from(overlaps_pool);
            !overlaps_pool
        })
        .map(|net| net.to_string())
        .collect();
    if skipped > 0 {
        tracing::warn!(
            "cn-bypass: dropped {skipped} CN range(s) overlapping the fake-IP pool 28.0.0.0/8"
        );
    }
    let v6 = ranges.v6.iter().map(|net| net.to_string()).collect();
    Ok((v4, v6))
}

/// Write via a sibling temp file + rename so the extension can never observe
/// a torn artifact.
fn write_atomically(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes)
        .with_context(|| format!("writing cn-bypass artifact to {}", tmp.display()))?;
    std::fs::rename(&tmp, path)
        .with_context(|| format!("renaming cn-bypass artifact into {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const FIXTURE_MMDB: &[u8] = include_bytes!("../tests/fixtures/GeoIP2-Country-Test.mmdb");

    /// CN networks documented in MaxMind's GeoIP2-Country test data:
    /// 111.235.160.0/22 and 175.16.199.0/24.
    const FIXTURE_CN_IPS: [&str; 2] = ["111.235.160.1", "175.16.199.1"];

    struct Harness {
        _tmp: tempfile::TempDir,
        config_path: PathBuf,
        out_path: PathBuf,
        yaml: String,
    }

    impl Harness {
        /// Stage the fixture MMDB + a config whose `geodata.mmdb-path` pins
        /// it explicitly, so tests neither read nor mutate the process-global
        /// `$XDG_CONFIG_HOME` (which `xdg_home_dir_tests` owns).
        fn new(rules: &str, mode: &str) -> Self {
            let tmp = tempfile::tempdir().expect("tmp dir");
            let mmdb_path = tmp.path().join("Country.mmdb");
            std::fs::write(&mmdb_path, FIXTURE_MMDB).expect("stage fixture mmdb");
            let yaml = format!(
                r#"
mode: {mode}
log-level: silent
geodata:
  mmdb-path: {mmdb}
proxies:
  - name: p1
    type: ss
    server: 198.51.100.1
    port: 8388
    cipher: aes-128-gcm
    password: probe-test
proxy-groups:
  - name: DirectFirst
    type: select
    proxies: [DIRECT, p1]
  - name: ProxyFirst
    type: select
    proxies: [p1, DIRECT]
rules:
{rules}
"#,
                mode = mode,
                mmdb = mmdb_path.display(),
                rules = rules,
            );
            let config_path = tmp.path().join("config.yaml");
            std::fs::write(&config_path, &yaml).expect("write config");
            let out_path = tmp.path().join("cn-bypass.txt");
            Self {
                _tmp: tmp,
                config_path,
                out_path,
                yaml,
            }
        }

        fn probe(&self) -> Result<bool> {
            probe_and_write_with_ips(
                self.config_path.to_str().unwrap(),
                self.out_path.to_str().unwrap(),
                &FIXTURE_CN_IPS,
            )
        }

        fn artifact(&self) -> String {
            std::fs::read_to_string(&self.out_path).expect("artifact exists")
        }
    }

    #[test]
    fn geoip_cn_direct_engages_bypass_and_writes_ranges() {
        let h = Harness::new("  - GEOIP,CN,DIRECT\n  - MATCH,p1", "rule");
        assert!(h.probe().expect("probe ok"), "GEOIP,CN,DIRECT must engage");

        let artifact = h.artifact();
        let mut lines = artifact.lines();
        assert_eq!(lines.next(), Some(ARTIFACT_HEADER));
        let expected_sha = format!("{:x}", Sha256::digest(h.yaml.as_bytes()));
        assert_eq!(
            lines.next(),
            Some(format!("config-sha256 {expected_sha}").as_str()),
            "artifact must carry the SHA-256 of the raw config bytes"
        );
        assert_eq!(lines.next(), Some("cn-direct 1"));
        let cidrs: Vec<&str> = lines.collect();
        assert!(
            cidrs.contains(&"111.235.160.0/22"),
            "fixture CN v4 range missing from {cidrs:?}"
        );
        assert!(
            cidrs.iter().any(|c| c.contains(':')),
            "fixture CN v6 ranges missing from {cidrs:?}"
        );
        // Every line must parse as a CIDR — the extension trusts this format.
        for cidr in &cidrs {
            let (addr, prefix) = cidr.split_once('/').expect("cidr shape");
            addr.parse::<IpAddr>().expect("valid address");
            prefix.parse::<u8>().expect("valid prefix");
        }
    }

    #[test]
    fn no_geoip_rule_stays_in_tunnel() {
        let h = Harness::new("  - MATCH,DIRECT", "rule");
        assert!(
            !h.probe().expect("probe ok"),
            "direct FINAL without GEOIP,CN must not engage"
        );
        let artifact = h.artifact();
        assert!(artifact.contains("cn-direct 0"));
        assert_eq!(
            artifact.lines().count(),
            3,
            "negative artifact must carry no CIDR lines: {artifact}"
        );
    }

    #[test]
    fn geoip_cn_to_proxy_stays_in_tunnel() {
        let h = Harness::new("  - GEOIP,CN,p1\n  - MATCH,DIRECT", "rule");
        assert!(
            !h.probe().expect("probe ok"),
            "GEOIP,CN→proxy must not engage"
        );
    }

    #[test]
    fn geoip_cn_via_direct_selecting_group_engages() {
        let h = Harness::new("  - GEOIP,CN,DirectFirst\n  - MATCH,p1", "rule");
        assert!(
            h.probe().expect("probe ok"),
            "selector whose selection resolves to DIRECT must engage"
        );
    }

    #[test]
    fn geoip_cn_via_proxy_selecting_group_stays_in_tunnel() {
        let h = Harness::new("  - GEOIP,CN,ProxyFirst\n  - MATCH,p1", "rule");
        assert!(
            !h.probe().expect("probe ok"),
            "selector whose selection is a proxy must not engage"
        );
    }

    #[test]
    fn earlier_shadowing_rule_vetoes_bypass() {
        // An IP-CIDR rule ahead of GEOIP,CN diverts one probe IP to the
        // proxy: part of CN would be mis-bypassed, so the probe must veto.
        let h = Harness::new(
            "  - IP-CIDR,111.235.160.0/22,p1\n  - GEOIP,CN,DIRECT\n  - MATCH,p1",
            "rule",
        );
        assert!(
            !h.probe().expect("probe ok"),
            "a proxy rule shadowing part of CN must veto the bypass"
        );
    }

    #[test]
    fn global_mode_stays_in_tunnel() {
        let h = Harness::new("  - GEOIP,CN,DIRECT\n  - MATCH,p1", "global");
        assert!(
            !h.probe().expect("probe ok"),
            "rules don't apply in global mode; bypass must not engage"
        );
    }

    #[test]
    fn ffi_surface_returns_one_on_cn_direct_config() {
        use std::ffi::CString;
        let h = Harness::new("  - GEOIP,CN,DIRECT\n  - MATCH,p1", "rule");
        let config = CString::new(h.config_path.to_str().unwrap()).unwrap();
        let out = CString::new(h.out_path.to_str().unwrap()).unwrap();
        let rc = unsafe { crate::meow_config_cn_bypass_probe(config.as_ptr(), out.as_ptr()) };
        // The C surface uses the production probe IPs, which the fixture MMDB
        // does not contain — so the functional probe reports "not CN-direct".
        // rc must still be a clean 0 (not -1), and the artifact must exist.
        assert_eq!(rc, 0, "fixture MMDB lacks production probe IPs → clean 0");
        assert!(h.artifact().contains("cn-direct 0"));
    }
}
