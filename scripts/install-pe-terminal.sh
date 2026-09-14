#!/usr/bin/env bash

# Installer for Izuma Edge pe-terminal.
#
# Supported hosts:
#   - Ubuntu 20.04 / 22.04 / 24.04, Debian 13   (.deb package)
#   - AlmaLinux 9 / Rocky 9 / RHEL 9 (.rpm package)
#
# - Installs the pe-terminal package (only if not already installed)
# - Enables and starts the pe-terminal service
# - Performs validation checks to ensure the service is running
#
# NOTE: pe-terminal requires edge-proxy to be running. Install and start
# thick-edge services first using install-thick-edge-services.sh.
#
# pe-terminal is installed from the Izuma package repository (signed .deb/.rpm
# metadata) - see lib/distro.sh's "Izuma package repository" section for the
# IZUMA_REPO_DOMAIN / IZUMA_RPM_REPO_NAME / IZUMA_DEB_REPO_NAME /
# IZUMA_REPO_SIGNING_KEY_URL overrides.

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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found"
}

install_pe_terminal() {
  if pkg_is_installed "pe-terminal"; then
    log "Package 'pe-terminal' is already installed, skipping"
    return 0
  fi

  setup_izuma_repo

  if ! pkg_available "pe-terminal"; then
    local repo_name="$IZUMA_RPM_REPO_NAME"
    [ "$PKG_FAMILY" = "debian" ] && repo_name="$IZUMA_DEB_REPO_NAME"
    warn "pe-terminal is not available from the Izuma package repository"
    warn "(https://${IZUMA_REPO_DOMAIN}/pulp/content/${repo_name}/)."
    if [ "$PKG_FAMILY" = "rhel" ]; then
      warn "An RPM build of pe-terminal may not be published yet. Point"
      warn "IZUMA_REPO_DOMAIN (and IZUMA_RPM_REPO_NAME if needed) at your own"
      warn "repository once you have built it."
    fi
    die "Could not find the pe-terminal package"
  fi

  log "Installing pe-terminal"
  pkg_install "pe-terminal"
}

# A unit installed moments ago by the package manager is not visible to
# `systemctl list-unit-files` until systemd reloads, so fall back to looking on
# disk. Without this, a first-time install reports every freshly installed
# service as missing.
service_exists() {
  systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q . && return 0

  local dir
  for dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    [ -f "${dir}/$1.service" ] && return 0
  done
  return 1
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
      warn "✗ Service '$svc' is not installed (no unit file)"
      failed+=("$svc")
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
  pkg_install_optional ca-certificates curl
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
  require_cmd curl

  detect_distro
  log "Detected ${DISTRO_ID} ${DISTRO_VERSION_ID} (${PKG_FAMILY} family, ${PKG_ARCH})"

  ensure_prerequisites
  check_edge_proxy

  install_pe_terminal
  sudo systemctl daemon-reload

  start_enable_service pe-terminal

  log "Validating services..."
  validate_services pe-terminal

  echo ""
  log "✓ Installation and validation completed successfully."
}

main "$@"
