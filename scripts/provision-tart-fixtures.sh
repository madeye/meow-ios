#!/usr/bin/env bash
#
# Idempotent Tart-guest provisioning for the protocol fixture binaries
# consumed by scripts/test-e2e-ios.sh. Layered on top of the existing
# `bld-e2e-base` image (per team-lead: reuse the local base, do not
# rebake) so repeated runs only install what's missing.
#
# Runs in two modes:
#   - inside the Tart macOS guest (most common): installs/downloads
#     directly onto the guest's filesystem.
#   - on a developer laptop: same provisioning, so `scripts/test-e2e-ios.sh`
#     can be exercised locally without a Tart boot (MEOW_FIXTURE_SEEDED=1).
#
# What gets installed / downloaded:
#   - Homebrew core formulas:
#       shadowsocks-rust, trojan-go, xray, wireguard-tools, wireguard-go
#   - GitHub release binaries dropped into /usr/local/bin:
#       hysteria         (apernet/hysteria — no homebrew-core formula)
#       tuic-server      (EAimTY/tuic       — no homebrew-core formula)
#
# No pre-shared secrets touched; the per-run ephemeral credentials are
# still generated inside test-e2e-ios.sh. This script only lays down
# binaries.
#
# Env:
#   HYSTERIA_VERSION     default "v2.6.0"  (override to pin)
#   TUIC_VERSION         default "v1.0.0"  (override to pin)
#   BIN_DIR              default /usr/local/bin
#   DRY_RUN=1            print what would be done, change nothing
#
# Exit codes:
#   0  — every fixture binary is present (no-op or installed successfully)
#   1  — a required tool (brew, curl) is missing
#   2  — an install step failed; detail in stderr

set -euo pipefail

HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.0}"
TUIC_VERSION="${TUIC_VERSION:-v1.0.0}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
DRY_RUN="${DRY_RUN:-}"

log()  { printf '[provision-tart] %s\n' "$*"; }
warn() { printf '[provision-tart] WARN: %s\n' "$*" >&2; }
fail() { printf '[provision-tart] FAIL: %s\n' "$*" >&2; exit 2; }

run() {
  if [ -n "$DRY_RUN" ]; then
    log "DRY: $*"
  else
    "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { warn "missing $1"; return 1; }
}

uname_arch() {
  local a
  a="$(uname -m)"
  case "$a" in
    arm64|aarch64) echo "arm64" ;;
    x86_64)        echo "amd64" ;;
    *)             echo "$a"    ;;
  esac
}

detect_platform() {
  local arch
  arch="$(uname_arch)"
  case "$(uname -s)" in
    Darwin) echo "darwin-$arch" ;;
    Linux)  echo "linux-$arch"  ;;
    *)      echo "unknown-$arch" ;;
  esac
}

# --- Homebrew formulas ---
install_brew_formula() {
  local formula="$1" bin="$2"
  if command -v "$bin" >/dev/null 2>&1; then
    log "OK $bin present ($(command -v "$bin"))"
    return 0
  fi
  require_cmd brew || { warn "brew unavailable; cannot install $formula"; return 1; }
  log "installing $formula..."
  run brew install "$formula" >/dev/null || fail "brew install $formula"
  if [ -z "$DRY_RUN" ]; then
    command -v "$bin" >/dev/null 2>&1 || fail "$formula installed but $bin not on PATH"
  fi
}

# --- GitHub release binary drop ---
install_release_binary() {
  local name="$1" url="$2" target="$BIN_DIR/$1"
  if [ -x "$target" ]; then
    log "OK $name present at $target"
    return 0
  fi
  require_cmd curl || { warn "curl unavailable; cannot fetch $name"; return 1; }
  log "downloading $name from $url"
  run curl -fsSL "$url" -o "$target.part" || fail "download $name"
  run chmod +x "$target.part"
  run mv "$target.part" "$target"
  log "OK installed $name -> $target"
}

main() {
  local platform arch
  platform="$(detect_platform)"
  arch="$(uname_arch)"
  log "platform=$platform  bin_dir=$BIN_DIR  dry_run=${DRY_RUN:-0}"

  # Homebrew-core formulas (per TEST_FIXTURES.md §5 Tart image ask)
  install_brew_formula shadowsocks-rust ssserver
  install_brew_formula trojan-go        trojan-go
  install_brew_formula xray             xray
  install_brew_formula wireguard-tools  wg
  install_brew_formula wireguard-go     wireguard-go

  # GitHub release binaries (no homebrew-core formula as of 2026-04).
  # URL patterns follow the upstream release conventions; pin via env.
  local hy2_url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-${platform}"
  local tuic_url="https://github.com/EAimTY/tuic/releases/download/tuic-server-${TUIC_VERSION#v}/tuic-server-${TUIC_VERSION#v}-${arch}-apple-darwin"
  install_release_binary hysteria    "$hy2_url"
  install_release_binary tuic-server "$tuic_url"

  log "summary:"
  for bin in ssserver trojan-go xray wg wireguard-go hysteria tuic-server; do
    if command -v "$bin" >/dev/null 2>&1; then
      printf '  OK %-14s %s\n' "$bin" "$(command -v "$bin")"
    else
      printf '  -- %-14s MISSING\n' "$bin"
    fi
  done
}

main "$@"
