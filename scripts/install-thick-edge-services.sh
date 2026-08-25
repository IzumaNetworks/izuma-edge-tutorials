#!/usr/bin/env bash

# Installer for Izuma Edge thick-edge services.
#
# Supported hosts:
#   - Ubuntu 20.04 / 22.04 / 24.04   (.deb packages)
#   - AlmaLinux 9 / Rocky 9 / RHEL 9 (.rpm packages)
#
# - Installs the required native packages (only if not already installed)
# - Installs kubelet launch scripts, kube-router, and CoreDNS
# - Prepares host networking (kernel modules, sysctls, NetworkManager)
# - Enables and starts services
# - Performs validation checks to ensure everything is running
#
# Environment overrides:
#   IZUMA_PKG_BASE_URL=<url>   where to fetch the native packages from
#   IZUMA_TARBALL_BASE_URL=<url>  where to fetch the service tarballs from
#   SKIP_PACKAGE_INSTALL=1     skip the native package stage entirely
#                              (useful while packages for your distro are still
#                              being built - the tarball services are portable)

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

# ---------------------------------------------------------------------------
# Package sources
#
# The thick-edge components are published as native packages per distro family,
# plus a set of distro-independent tarballs (plain binaries + an install.sh).
# ---------------------------------------------------------------------------
IZUMA_CATALOG="http://izs3-catalog.izuma.io"
IZUMA_TARBALL_BASE_URL="${IZUMA_TARBALL_BASE_URL:-${IZUMA_CATALOG}/edge-debian-pkg}"

default_pkg_base_url() {
  case "$PKG_FAMILY" in
    debian) echo "${IZUMA_CATALOG}/edge-debian-pkg/deb/focal/main/binary-${PKG_ARCH}" ;;
    rhel)   echo "${IZUMA_CATALOG}/edge-rpm-pkg/rpm/$(rhel_el_tag)/main/${PKG_ARCH}" ;;
  esac
}

# name:upstream-version:package-release
IZUMA_PACKAGES=(
  "pe-utils:2.3.4:1"
  "edge-proxy:1.3.0:1"
  "containernetworking-plugins-c2d:0.8.5:1"
  "kubelet:1.1.0:1"
)

# Build the package filename for this distro family.
#   debian: pe-utils_2.3.4-1_amd64.deb
#   rhel:   pe-utils-2.3.4-1.el9.x86_64.rpm
pkg_filename() {
  local name="$1" version="$2" release="$3"
  case "$PKG_FAMILY" in
    debian) echo "${name}_${version}-${release}_${PKG_ARCH}.deb" ;;
    rhel)   echo "${name}-${version}-${release}.$(rhel_el_tag).${PKG_ARCH}.rpm" ;;
  esac
}

url_exists() {
  curl -fsSL -I -o /dev/null --max-time 20 "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Installation helpers
# ---------------------------------------------------------------------------
install_package_if_missing() {
  local package="$1"
  local url="$2"

  if pkg_is_installed "$package"; then
    log "Package '$package' is already installed, skipping"
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"

  local filename
  filename="${tmpdir}/$(basename "$url")"
  log "Downloading $(basename "$url")"
  if ! wget -q -O "$filename" "$url"; then
    rm -rf "$tmpdir"
    die "Failed to download $url"
  fi
  log "Installing $(basename "$url")"
  pkg_install_local "$filename"
  rm -rf "$tmpdir"
}

install_from_tarball() {
  local url="$1"
  local expected_dir="$2"
  local service_name="$3"

  if service_active "$service_name"; then
    log "Service '$service_name' is already active, skipping tarball install"
    return 0
  fi

  # Stop the service before overwriting its binary to avoid "Text file busy"
  if service_exists "$service_name"; then
    log "Stopping '$service_name' before reinstall"
    sudo systemctl stop "$service_name" 2>/dev/null || true
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"

  local tarball
  tarball="${tmpdir}/$(basename "$url")"
  log "Downloading $(basename "$url")"
  wget -q -O "$tarball" "$url"
  log "Extracting $(basename "$url")"
  tar -xzf "$tarball" -C "$tmpdir"

  # Find the extracted directory
  local extracted_dir
  extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -not -path "$tmpdir" | head -n1)"
  [ -n "$extracted_dir" ] || { rm -rf "$tmpdir"; die "Failed to locate extracted directory for $(basename "$url")"; }

  log "Running installer in $(basename "$extracted_dir")"
  (cd "$extracted_dir" && sudo ./install.sh)
  rm -rf "$tmpdir"
}

service_exists() {
  systemctl list-unit-files | grep -q "^$1.service" 2>/dev/null
}

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
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
  local failed
  failed=()
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
    printf ' - %s\n' "${failed[@]+"${failed[@]}"}" >&2
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

# ---------------------------------------------------------------------------
# Host networking prerequisites
#
# Ubuntu's docker.io/docker-ce packaging loads br_netfilter and turns on
# forwarding as a side effect. A minimal RHEL 9 image does neither, and without
# them kube-router's iptables rules never see bridged traffic and CoreDNS is
# unreachable from pods.
# ---------------------------------------------------------------------------
configure_host_networking() {
  log "Loading kernel modules required by kube-router"
  sudo tee /etc/modules-load.d/izuma-edge.conf >/dev/null <<'EOF'
# Required by the Izuma Edge kube-router CNI
overlay
br_netfilter
ip_vs
nf_conntrack
EOF
  local mod
  for mod in overlay br_netfilter ip_vs nf_conntrack; do
    sudo modprobe "$mod" 2>/dev/null || warn "Could not load kernel module '$mod'"
  done

  log "Applying sysctl settings required by kube-router"
  sudo tee /etc/sysctl.d/99-izuma-edge.conf >/dev/null <<'EOF'
# Required by the Izuma Edge kube-router CNI
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sudo sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported errors"
}

# NetworkManager (default on RHEL 9, absent on Ubuntu Server) claims the bridge
# and veth interfaces that kube-router creates and tears their addressing down.
configure_network_manager() {
  systemctl is-active --quiet NetworkManager 2>/dev/null || return 0

  local conf="/etc/NetworkManager/conf.d/99-izuma-edge-unmanaged.conf"
  log "Telling NetworkManager to leave the CNI interfaces alone ($conf)"
  sudo mkdir -p /etc/NetworkManager/conf.d
  sudo tee "$conf" >/dev/null <<'EOF'
# The Izuma Edge kube-router CNI manages these interfaces itself.
[keyfile]
unmanaged-devices=interface-name:kube-bridge;interface-name:kube-dummy-if;interface-name:cni0;interface-name:docker0;interface-name:veth*;interface-name:tun-*
EOF
  sudo systemctl reload NetworkManager 2>/dev/null || sudo systemctl restart NetworkManager 2>/dev/null || true
}

# kube-router 1.2.0 shells out to the iptables binary. RHEL 9 defaults to the
# nft backend, which cannot see rules written by the legacy backend (and vice
# versa), so a mismatch produces silently broken pod networking.
check_iptables_backend() {
  [ "$PKG_FAMILY" = "rhel" ] || return 0
  command -v iptables >/dev/null 2>&1 || return 0

  local backend
  backend="$(iptables --version 2>/dev/null | grep -o 'nf_tables\|legacy' || echo unknown)"
  log "iptables backend is '${backend}'"
  if [ "$backend" = "nf_tables" ]; then
    warn "RHEL 9 uses the iptables nf_tables backend. If pod networking or CoreDNS"
    warn "misbehaves, check that kube-router's rules landed in the same backend:"
    warn "    sudo iptables-save | grep -i kube"
    warn "    sudo nft list ruleset | grep -i kube"
  fi
}

ensure_prerequisites() {
  pkg_refresh
  # tar/gzip are always present on Ubuntu but not in a minimal RHEL image,
  # and the service tarballs cannot be unpacked without them.
  pkg_install_optional ca-certificates wget tar gzip iproute2 ipset
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

# Confirm the native packages for this distro actually exist before starting,
# so a distro without published packages fails with a clear message instead of
# a half-installed system.
preflight_packages() {
  local base_url="$1"
  local missing=()
  local entry name version release filename

  log "Checking package availability at ${base_url}"
  for entry in "${IZUMA_PACKAGES[@]}"; do
    IFS=: read -r name version release <<<"$entry"
    pkg_is_installed "$name" && continue
    filename="$(pkg_filename "$name" "$version" "$release")"
    url_exists "${base_url}/${filename}" || missing+=("$filename")
  done

  [ "${#missing[@]}" -eq 0 ] && return 0

  echo "" >&2
  warn "These ${PKG_EXT} packages are not available at ${base_url}:"
  printf '  - %s\n' "${missing[@]}" >&2
  echo "" >&2
  if [ "$PKG_FAMILY" = "rhel" ]; then
    warn "RPM builds of the thick-edge components are not published yet."
    warn "Point IZUMA_PKG_BASE_URL at your own repository once you have built them:"
    warn "    IZUMA_PKG_BASE_URL=https://my-host/rpms ./scripts/install-thick-edge-services.sh"
  fi
  warn "To install only the distro-independent tarball services for now, re-run with:"
  warn "    SKIP_PACKAGE_INSTALL=1 ./scripts/install-thick-edge-services.sh"
  return 1
}

install_native_packages() {
  local base_url="$1"
  local entry name version release

  for entry in "${IZUMA_PACKAGES[@]}"; do
    IFS=: read -r name version release <<<"$entry"
    install_package_if_missing "$name" "${base_url}/$(pkg_filename "$name" "$version" "$release")"
  done
}

main() {
  log "Starting Izuma Edge thick-edge services installation"

  require_cmd sudo
  require_cmd systemctl
  require_cmd curl

  detect_distro
  log "Detected ${DISTRO_ID} ${DISTRO_VERSION_ID} (${PKG_FAMILY} family, ${PKG_ARCH})"

  ensure_prerequisites
  require_cmd wget
  require_cmd tar

  check_selinux
  check_firewalld
  check_iptables_backend

  local pkg_base_url
  pkg_base_url="${IZUMA_PKG_BASE_URL:-$(default_pkg_base_url)}"

  if [ "${SKIP_PACKAGE_INSTALL:-0}" = "1" ]; then
    warn "SKIP_PACKAGE_INSTALL=1 - skipping the native ${PKG_EXT} package stage."
    warn "edge-proxy, kubelet and pe-utils will NOT be installed by this run."
  else
    preflight_packages "$pkg_base_url" || die "Required ${PKG_EXT} packages are unavailable; see above."
    install_native_packages "$pkg_base_url"
  fi

  # Install kubelet launch scripts
  install_from_tarball "${IZUMA_TARBALL_BASE_URL}/kubelet.tar.gz" "kubelet" "kubelet"

  # Clean up any conflicting old units
  cleanup_old_services

  # Install kube-router and CoreDNS
  install_from_tarball "${IZUMA_TARBALL_BASE_URL}/kube-router_1_2_0_1.tar.gz" "kube-router" "kube-router"
  install_from_tarball "${IZUMA_TARBALL_BASE_URL}/coredns.tar.gz" "coredns" "coredns"

  # Host networking must be in place before kube-router starts
  configure_host_networking
  configure_network_manager

  # Configure networking for kube-router/CoreDNS bridge
  configure_kube_bridge

  # Enable and start services
  start_enable_service edge-proxy
  start_enable_service kubelet
  start_enable_service kube-router
  start_enable_service coredns

  # Validate services, including optional wait-for-pelion-identity if present
  local to_check
  to_check=(edge-proxy kubelet kube-router coredns)
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
  log "Installing pe-terminal..."
  bash "${SCRIPT_DIR}/install-pe-terminal.sh"

  log "✓ Installation and validation completed successfully."
}

main "$@"
