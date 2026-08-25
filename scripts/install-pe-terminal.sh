#!/usr/bin/env bash

# Installer for Izuma Edge pe-terminal.
#
# Supported hosts:
#   - Ubuntu 20.04 / 22.04 / 24.04   (.deb package)
#   - AlmaLinux 9 / Rocky 9 / RHEL 9 (.rpm package)
#
# - Installs the pe-terminal package (only if not already installed)
# - Enables and starts the pe-terminal service
# - Performs validation checks to ensure the service is running
#
# NOTE: pe-terminal requires edge-proxy to be running. Install and start
# thick-edge services first using install-thick-edge-services.sh.
#
# Environment overrides:
#   IZUMA_PKG_BASE_URL=<url>  where to fetch the pe-terminal package from

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  echo "[install] $*"
}

warn() {
  echo "[warn] $*" >&2
}

die() {
  echo "[error] $*" >&2
  exit 1
}

# shellcheck source=lib/distro.sh
. "${SCRIPT_DIR}/lib/distro.sh"

IZUMA_CATALOG="http://izs3-catalog.izuma.io"
PE_TERMINAL_VERSION="1.1.0"
PE_TERMINAL_RELEASE="1"

pe_terminal_url() {
  local base
  case "$PKG_FAMILY" in
    debian)
      base="${IZUMA_PKG_BASE_URL:-${IZUMA_CATALOG}/edge-debian-pkg/deb/focal/main/binary-${PKG_ARCH}}"
      echo "${base}/pe-terminal_${PE_TERMINAL_VERSION}-${PE_TERMINAL_RELEASE}_${PKG_ARCH}.deb"
      ;;
    rhel)
      base="${IZUMA_PKG_BASE_URL:-${IZUMA_CATALOG}/edge-rpm-pkg/rpm/$(rhel_el_tag)/main/${PKG_ARCH}}"
      echo "${base}/pe-terminal-${PE_TERMINAL_VERSION}-${PE_TERMINAL_RELEASE}.$(rhel_el_tag).${PKG_ARCH}.rpm"
      ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found"
}

install_package_if_missing() {
  local package="$1"
  local url="$2"

  if pkg_is_installed "$package"; then
    log "Package '$package' is already installed, skipping"
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf ${tmpdir}" RETURN

  local filename
  filename="${tmpdir}/$(basename "$url")"
  log "Downloading $(basename "$url")"
  if ! wget -q -O "$filename" "$url"; then
    warn "Failed to download $url"
    if [ "$PKG_FAMILY" = "rhel" ]; then
      warn "An RPM build of pe-terminal may not be published yet. Point"
      warn "IZUMA_PKG_BASE_URL at your own repository once you have built it."
    fi
    die "Could not fetch the pe-terminal package"
  fi
  log "Installing $(basename "$url")"
  pkg_install_local "$filename"
}

service_exists() {
  systemctl list-unit-files | grep -q "^$1.service" 2>/dev/null
}

start_enable_service() {
  local svc="$1"
  if service_exists "$svc"; then
    log "Enabling and starting service '$svc'"
    sudo systemctl daemon-reload
    sudo systemctl enable "$svc" || true
    sudo systemctl restart "$svc" || true
  else
    warn "Service '$svc' is not installed (unit file missing)."
  fi
}

wait_for_active() {
  local svc="$1"
  local timeout="${2:-30}"
  local elapsed=0

  while ! systemctl is-active --quiet "$svc" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$timeout" ]; then
      return 1
    fi
  done
  return 0
}

validate_services() {
  local failed=()
  for svc in "$@"; do
    if service_exists "$svc"; then
      if wait_for_active "$svc" 45; then
        log "✓ Service '$svc' is active"
      else
        warn "✗ Service '$svc' failed to become active"
        failed+=("$svc")
      fi
    else
      warn "Service '$svc' might still be starting; skipping validation"
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    echo "" >&2
    echo "The following services are not active:" >&2
    printf ' - %s\n' "${failed[@]}" >&2
    return 1
  fi
}

ensure_prerequisites() {
  pkg_refresh
  pkg_install_optional ca-certificates wget
}

check_edge_proxy() {
  if ! systemctl is-active --quiet edge-proxy 2>/dev/null; then
    warn "Service 'edge-proxy' is not active. pe-terminal requires edge-proxy to function."
    warn "Run install-thick-edge-services.sh first to set up thick-edge services."
  fi
}

main() {
  log "Starting pe-terminal installation"

  require_cmd sudo
  require_cmd systemctl

  detect_distro
  log "Detected ${DISTRO_ID} ${DISTRO_VERSION_ID} (${PKG_FAMILY} family, ${PKG_ARCH})"

  ensure_prerequisites
  require_cmd wget
  check_edge_proxy

  install_package_if_missing "pe-terminal" "$(pe_terminal_url)"

  start_enable_service pe-terminal

  log "Validating services..."
  validate_services pe-terminal

  echo ""
  log "✓ Installation and validation completed successfully."
}

main "$@"
