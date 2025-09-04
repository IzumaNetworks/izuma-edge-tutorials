#!/usr/bin/env bash

# Robust installer for Izuma Edge thick-edge services on Debian/Ubuntu systems.
# - Installs required .deb packages (only if not already installed)
# - Installs kubelet launch scripts, kube-router, and CoreDNS
# - Enables and starts services
# - Performs validation checks to ensure everything is running

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

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
  trap 'rm -rf "${tmpdir}"' RETURN
  
  local filename
  filename="${tmpdir}/$(basename "$url")"
  log "Downloading $(basename "$url")"
  wget -q -O "$filename" "$url"
  log "Installing $(basename "$url")"
  sudo apt-get install -y "$filename"
}

install_from_tarball() {
  local url="$1"
  local expected_dir="$2"
  local service_name="$3"
  
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  
  local tarball
  tarball="${tmpdir}/$(basename "$url")"
  log "Downloading $(basename "$url")"
  wget -q -O "$tarball" "$url"
  log "Extracting $(basename "$url")"
  tar -xzf "$tarball" -C "$tmpdir"
  
  # Find the extracted directory
  local extracted_dir
  extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -not -path "$tmpdir" | head -n1)"
  [ -n "$extracted_dir" ] || die "Failed to locate extracted directory for $(basename "$url")"
  
  log "Running installer in $(basename "$extracted_dir")"
  (cd "$extracted_dir" && sudo ./install.sh)
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

configure_kube_bridge() {
  if ip link show kube-bridge >/dev/null 2>&1; then
    log "Configuring kube-bridge interface"
    sudo ip addr add 172.21.2.1/24 dev kube-bridge 2>/dev/null || true
    sudo ip link set kube-bridge up 2>/dev/null || true
  else
    warn "Interface 'kube-bridge' not present; skipping IP configuration"
  fi
}

ensure_prerequisites() {
  # Update package lists
  sudo apt-get update -y
  
  # Install required tools
  sudo apt-get install -y ca-certificates wget iproute2 ipset || true
}

cleanup_old_services() {
  for svc in kube-router coredns; do
    if systemctl list-units --full -all | grep -Fq "${svc}.service" 2>/dev/null; then
      log "Cleaning up old '$svc' service"
      sudo systemctl stop "$svc" 2>/dev/null || true
      sudo systemctl disable "$svc" 2>/dev/null || true
      sudo systemctl reset-failed "$svc" 2>/dev/null || true
      sudo rm -f "/etc/systemd/system/${svc}.service"
      sudo systemctl daemon-reload
    fi
  done
}

main() {
  log "Starting Izuma Edge thick-edge services installation"
  
  require_cmd sudo
  require_cmd systemctl
  require_cmd wget
  
  ensure_prerequisites
  
  # Install core deb packages (only if missing)
  install_deb_if_missing "pe-utils" "http://izs3-catalog.izuma.io/edge-debian-pkg/deb/focal/main/binary-amd64/pe-utils_2.3.4-1_amd64.deb"
  install_deb_if_missing "edge-proxy" "http://izs3-catalog.izuma.io/edge-debian-pkg/deb/focal/main/binary-amd64/edge-proxy_1.3.0-1_amd64.deb"
  install_deb_if_missing "containernetworking-plugins-c2d" "http://izs3-catalog.izuma.io/edge-debian-pkg/deb/focal/main/binary-amd64/containernetworking-plugins-c2d_0.8.5-1_amd64.deb"
  install_deb_if_missing "kubelet" "http://izs3-catalog.izuma.io/edge-debian-pkg/deb/focal/main/binary-amd64/kubelet_1.1.0-1_amd64.deb"
  
  # Install kubelet launch scripts
  install_from_tarball "http://izs3-catalog.izuma.io/edge-debian-pkg/kubelet.tar.gz" "kubelet" "kubelet"
  
  # Clean up any conflicting old units
  cleanup_old_services
  
  # Install kube-router and CoreDNS
  install_from_tarball "http://izs3-catalog.izuma.io/edge-debian-pkg/kube-router_1_2_0_1.tar.gz" "kube-router" "kube-router"
  install_from_tarball "http://izs3-catalog.izuma.io/edge-debian-pkg/coredns.tar.gz" "coredns" "coredns"
  
  # Configure networking for kube-router/CoreDNS bridge
  configure_kube_bridge
  
  # Enable and start services
  start_enable_service edge-proxy
  start_enable_service kubelet
  start_enable_service kube-router
  start_enable_service coredns
  
  # Validate services, including optional wait-for-pelion-identity if present
  local to_check=(edge-proxy kubelet kube-router coredns)
  if service_exists wait-for-pelion-identity; then
    start_enable_service wait-for-pelion-identity || true
    to_check+=(wait-for-pelion-identity)
  fi
  
  log "Validating services..."
  validate_services "${to_check[@]}"
  
  # Optional device info (from pe-utils)
  if command -v edge-info >/dev/null 2>&1; then
    echo ""
    log "Edge info summary (edge-info -m):"
    sudo edge-info -m || true
  fi
  
  echo ""
  log "✓ Installation and validation completed successfully."
}

main "$@"