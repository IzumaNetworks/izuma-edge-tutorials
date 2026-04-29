#!/usr/bin/env bash

# Installer for Izuma Edge pe-terminal on Debian/Ubuntu systems.
# - Installs the pe-terminal .deb package (only if not already installed)
# - Enables and starts the pe-terminal service
# - Performs validation checks to ensure the service is running
#
# NOTE: pe-terminal requires edge-proxy to be running. Install and start
# thick-edge services first using install-thick-edge-services.sh.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

PE_TERMINAL_URL="http://izs3-catalog.izuma.io/edge-debian-pkg/deb/focal/main/binary-amd64/pe-terminal_1.1.0-1_amd64.deb"

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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found"
}

is_package_installed() {
  dpkg -l | grep -q "^ii.*$1 " 2>/dev/null
}

install_deb_if_missing() {
  local package="$1"
  local url="$2"

  if is_package_installed "$package"; then
    log "Package '$package' is already installed, skipping"
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf ${tmpdir}" RETURN

  local filename
  filename="${tmpdir}/$(basename "$url")"
  log "Downloading $(basename "$url")"
  wget -q -O "$filename" "$url"
  log "Installing $(basename "$url")"
  sudo apt-get install -y "$filename"
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
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates wget || true
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
  require_cmd wget

  ensure_prerequisites
  check_edge_proxy

  install_deb_if_missing "pe-terminal" "$PE_TERMINAL_URL"

  start_enable_service pe-terminal

  log "Validating services..."
  validate_services pe-terminal

  echo ""
  log "✓ Installation and validation completed successfully."
}

main "$@"
