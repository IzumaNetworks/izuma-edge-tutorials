#!/usr/bin/env bash
# shellcheck shell=bash
#
# Distro abstraction for the Izuma Edge tutorial scripts.
#
# Supports two package families:
#   debian - Ubuntu 20.04/22.04/24.04, Debian    (apt / dpkg / .deb)
#   rhel   - AlmaLinux 9, Rocky 9, RHEL 9, CentOS Stream 9 (dnf / rpm / .rpm)
#
# Source this file, then call detect_distro before anything else:
#
#   . "${SCRIPT_DIR}/lib/distro.sh"
#   detect_distro
#
# After detect_distro the following are set:
#   DISTRO_ID          - os-release ID, e.g. ubuntu, almalinux
#   DISTRO_VERSION_ID  - os-release VERSION_ID, e.g. 24.04, 9.8
#   DISTRO_CODENAME    - os-release VERSION_CODENAME, e.g. noble (debian only)
#   PKG_FAMILY         - debian | rhel
#   PKG_EXT            - deb | rpm
#   PKG_ARCH           - amd64 | arm64 (debian) or x86_64 | aarch64 (rhel)

# ---------------------------------------------------------------------------
# Logging (scripts may override these before sourcing)
# ---------------------------------------------------------------------------
if ! declare -F log >/dev/null 2>&1; then
  log() { echo "[install] $*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { echo "[warn] $*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { echo "[error] $*" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
detect_distro() {
  [ -r /etc/os-release ] || die "/etc/os-release not found; cannot identify this distribution"

  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_VERSION_ID="${VERSION_ID:-unknown}"
  DISTRO_CODENAME="${VERSION_CODENAME:-}"
  local id_like="${ID_LIKE:-}"

  case " $DISTRO_ID $id_like " in
    *" debian "*|*" ubuntu "*)
      PKG_FAMILY="debian"
      PKG_EXT="deb"
      PKG_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
      ;;
    *" rhel "*|*" fedora "*|*" centos "*)
      PKG_FAMILY="rhel"
      PKG_EXT="rpm"
      PKG_ARCH="$(uname -m)"
      ;;
    *)
      die "Unsupported distribution '$DISTRO_ID'. Supported: Ubuntu/Debian and RHEL 9 derivatives (AlmaLinux, Rocky, CentOS Stream)."
      ;;
  esac

  # The Izuma kubelet and its tooling are only published for these majors.
  case "$PKG_FAMILY" in
    rhel)
      case "${DISTRO_VERSION_ID%%.*}" in
        9) : ;;
        *) warn "Only RHEL 9 derivatives are validated; '$DISTRO_ID $DISTRO_VERSION_ID' may not work." ;;
      esac
      ;;
  esac

  export DISTRO_ID DISTRO_VERSION_ID DISTRO_CODENAME PKG_FAMILY PKG_EXT PKG_ARCH

  # apt must never prompt
  if [ "$PKG_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
  fi
}

# The RHEL "el" tag used in RPM release fields and repo URLs, e.g. el9
rhel_el_tag() {
  echo "el${DISTRO_VERSION_ID%%.*}"
}

# ---------------------------------------------------------------------------
# Canonical package names -> distro package names
#
# Only names that actually differ need an entry; anything else passes through.
# ---------------------------------------------------------------------------
map_pkg() {
  local name="$1"

  if [ "$PKG_FAMILY" = "debian" ]; then
    echo "$name"
    return 0
  fi

  # RHEL 9 equivalents. An empty result means "no equivalent, skip it".
  case "$name" in
    netcat-openbsd)            echo "nmap-ncat" ;;
    procps)                    echo "procps-ng" ;;
    dnsutils)                  echo "bind-utils" ;;
    gnupg)                     echo "gnupg2" ;;
    iproute2)                  echo "iproute" ;;
    build-essential)           echo "gcc gcc-c++ make" ;;
    software-properties-common) echo "dnf-plugins-core" ;;
    # apt-only concepts with no RPM counterpart
    apt-transport-https)       echo "" ;;
    lsb-release)               echo "" ;;
    *)                         echo "$name" ;;
  esac
}

# ---------------------------------------------------------------------------
# Package operations
# ---------------------------------------------------------------------------
pkg_refresh() {
  case "$PKG_FAMILY" in
    debian) sudo apt-get update -y ;;
    rhel)   sudo dnf -y makecache ;;
  esac
}

# pkg_install <canonical-name>...
pkg_install() {
  local mapped=() name resolved
  for name in "$@"; do
    resolved="$(map_pkg "$name")"
    # map_pkg may expand to several packages, or to nothing
    # shellcheck disable=SC2206
    [ -n "$resolved" ] && mapped+=($resolved)
  done
  [ "${#mapped[@]}" -gt 0 ] || return 0

  case "$PKG_FAMILY" in
    debian) sudo apt-get install -y "${mapped[@]}" ;;
    rhel)   sudo dnf install -y "${mapped[@]}" ;;
  esac
}

# Best-effort variant: never fails the script
pkg_install_optional() {
  pkg_install "$@" || warn "Some optional packages could not be installed; continuing"
}

pkg_is_installed() {
  case "$PKG_FAMILY" in
    debian) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok installed$" ;;
    rhel)   rpm -q "$1" >/dev/null 2>&1 ;;
  esac
}

# Install a package file downloaded to the local filesystem, pulling in
# whatever dependencies it declares.
pkg_install_local() {
  local file="$1"
  case "$PKG_FAMILY" in
    debian) sudo apt-get install -y "$file" ;;
    rhel)   sudo dnf install -y "$file" ;;
  esac
}

# Remove a package and its configuration
pkg_purge() {
  local pkg="$1"
  case "$PKG_FAMILY" in
    debian) sudo apt-get purge -y "$pkg" 2>/dev/null || true ;;
    rhel)   sudo dnf remove -y "$pkg" 2>/dev/null || true ;;
  esac
}

pkg_autoremove() {
  case "$PKG_FAMILY" in
    debian) sudo apt-get autoremove -y || true ;;
    rhel)   sudo dnf autoremove -y || true ;;
  esac
}

# Installed version string, empty when the package is absent.
# debian: 5:28.5.2-1~ubuntu.22.04~jammy
# rhel:   3:28.5.2-1.el9
pkg_installed_version() {
  case "$PKG_FAMILY" in
    debian) dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true ;;
    rhel)   rpm -q --qf '%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}' "$1" 2>/dev/null || true ;;
  esac
}

# Newest available version of $1 whose upstream major matches $2.
pkg_available_version_for_major() {
  local pkg="$1" major="$2"
  case "$PKG_FAMILY" in
    debian)
      apt-cache madison "$pkg" 2>/dev/null \
        | awk -v pin="$major" '$3 ~ ("^[0-9]+:" pin "\\.") { print $3; exit }'
      ;;
    rhel)
      # "docker-ce.x86_64   3:28.5.2-1.el9   docker-ce-stable" -> 3:28.5.2-1.el9
      sudo dnf -q --showduplicates list --available "$pkg" 2>/dev/null \
        | awk -v pin="$major" '$2 ~ ("^([0-9]+:)?" pin "\\.") { print $2 }' \
        | sort -V | tail -n1
      ;;
  esac
}

# List every available version of $1, for error messages.
pkg_available_versions() {
  case "$PKG_FAMILY" in
    debian) apt-cache madison "$1" 2>/dev/null | awk '{print $3}' ;;
    rhel)   sudo dnf -q --showduplicates list --available "$1" 2>/dev/null | awk 'NR>1 && $2 ~ /^[0-9]/ {print $2}' ;;
  esac
}

# Install exact versions: pkg_install_versioned name=version [name=version ...]
pkg_install_versioned() {
  local specs=() arg name version
  for arg in "$@"; do
    name="${arg%%=*}"
    version="${arg#*=}"
    case "$PKG_FAMILY" in
      debian) specs+=("${name}=${version}") ;;
      # dnf wants name-[epoch:]version-release
      rhel)   specs+=("${name}-${version}") ;;
    esac
  done

  case "$PKG_FAMILY" in
    debian) sudo apt-get install -y --allow-downgrades "${specs[@]}" ;;
    rhel)   sudo dnf install -y --allowerasing "${specs[@]}" ;;
  esac
}

# Pin packages so a routine system upgrade cannot move them.
pkg_hold() {
  case "$PKG_FAMILY" in
    debian)
      sudo apt-mark hold "$@" >/dev/null 2>&1 || true
      ;;
    rhel)
      if ! sudo dnf versionlock --help >/dev/null 2>&1; then
        sudo dnf install -y 'dnf-command(versionlock)' >/dev/null 2>&1 \
          || sudo dnf install -y python3-dnf-plugin-versionlock >/dev/null 2>&1 || true
      fi
      # Re-locking an already locked package errors out; clear first.
      sudo dnf versionlock delete "$@" >/dev/null 2>&1 || true
      sudo dnf versionlock add "$@" >/dev/null 2>&1 || warn "Could not versionlock: $*"
      ;;
  esac
}

pkg_unhold() {
  case "$PKG_FAMILY" in
    debian) sudo apt-mark unhold "$@" >/dev/null 2>&1 || true ;;
    rhel)   sudo dnf versionlock delete "$@" >/dev/null 2>&1 || true ;;
  esac
}

# Command that lifts the hold, for printing in closing instructions.
pkg_unhold_hint() {
  case "$PKG_FAMILY" in
    debian) echo "sudo apt-mark unhold $*" ;;
    rhel)   echo "sudo dnf versionlock delete $*" ;;
  esac
}

# ---------------------------------------------------------------------------
# Docker repository
# ---------------------------------------------------------------------------
setup_docker_repo() {
  case "$PKG_FAMILY" in
    debian) _setup_docker_repo_debian ;;
    rhel)   _setup_docker_repo_rhel ;;
  esac
}

_setup_docker_repo_debian() {
  sudo install -m 0755 -d /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    log "Downloading Docker GPG key"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  else
    log "Docker GPG key already present"
  fi
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  case "$DISTRO_CODENAME" in
    noble|jammy|focal)
      DOCKER_CODENAME="$DISTRO_CODENAME"
      log "Using Docker repository for Ubuntu $DOCKER_CODENAME"
      ;;
    *)
      DOCKER_CODENAME="jammy"
      warn "Unknown Ubuntu codename '$DISTRO_CODENAME'; falling back to jammy"
      ;;
  esac

  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo "deb [arch=${PKG_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  else
    log "Docker apt repository already configured"
  fi

  pkg_refresh
}

_setup_docker_repo_rhel() {
  # config-manager lives in dnf-plugins-core
  if ! sudo dnf config-manager --help >/dev/null 2>&1; then
    log "Installing dnf-plugins-core for repository management"
    sudo dnf install -y dnf-plugins-core
  fi

  # Docker publishes a CentOS repo that resolves $releasever correctly on all
  # RHEL 9 rebuilds (AlmaLinux, Rocky, CentOS Stream).
  if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
    log "Adding the Docker CE repository"
    sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo \
      || sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/centos/docker-ce.repo
  else
    log "Docker dnf repository already configured"
  fi

  # AlmaLinux reports $releasever as e.g. "9" already, but some rebuilds report
  # "9.8", which Docker's repo layout does not have. Pin it to the major.
  local major="${DISTRO_VERSION_ID%%.*}"
  if grep -q '\$releasever' /etc/yum.repos.d/docker-ce.repo 2>/dev/null \
     && [ "$(sudo dnf config-manager --dump docker-ce-stable 2>/dev/null | grep -c "centos/${major}/")" = "0" ]; then
    log "Pinning the Docker repository to \$releasever=${major}"
    sudo sed -i "s|/centos/\$releasever/|/centos/${major}/|g" /etc/yum.repos.d/docker-ce.repo
  fi

  pkg_refresh
}

# ---------------------------------------------------------------------------
# Kernel command line / bootloader
# ---------------------------------------------------------------------------
kernel_cmdline_has() {
  grep -qw -- "$1" /proc/cmdline
}

# Persist one or more kernel command-line arguments across reboots.
# Returns 0 if anything changed, 1 if the arguments were already configured.
bootloader_add_cmdline_args() {
  case "$PKG_FAMILY" in
    debian) _bootloader_add_args_debian "$@" ;;
    rhel)   _bootloader_add_args_rhel "$@" ;;
  esac
}

_bootloader_add_args_debian() {
  local grub_config="/etc/default/grub"
  local args="$*"
  local first="$1"

  if grep -q -- "$first" "$grub_config"; then
    log "Kernel argument '$first' is already present in $grub_config"
    return 1
  fi

  sudo cp "$grub_config" "${grub_config}.bak"
  log "Backed up $grub_config to ${grub_config}.bak"

  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_config"; then
    sudo sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)/\1 ${args}/" "$grub_config"
  else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${args}\"" | sudo tee -a "$grub_config" > /dev/null
  fi

  log "Regenerating the GRUB configuration"
  sudo update-grub
  return 0
}

_bootloader_add_args_rhel() {
  local grub_config="/etc/default/grub"
  local args="$*"
  local first="$1"
  local changed=1

  # RHEL 9 boots from BLS entries under /boot/loader/entries. grubby rewrites
  # every installed entry, which is what actually takes effect on next boot.
  if command -v grubby >/dev/null 2>&1; then
    if grubby --info=DEFAULT 2>/dev/null | grep -q -- "$first"; then
      log "Kernel argument '$first' is already set on the default boot entry"
    else
      log "Adding kernel arguments to all boot entries via grubby"
      sudo grubby --update-kernel=ALL --args="${args}"
      changed=0
    fi
  else
    warn "grubby not found; falling back to editing $grub_config only"
  fi

  # Also record it in /etc/default/grub so a future grub2-mkconfig, or a kernel
  # installed by a distro upgrade, inherits the setting.
  if [ -f "$grub_config" ] && ! grep -q -- "$first" "$grub_config"; then
    sudo cp "$grub_config" "${grub_config}.bak"
    log "Backed up $grub_config to ${grub_config}.bak"
    if grep -q '^GRUB_CMDLINE_LINUX=' "$grub_config"; then
      sudo sed -i "s/^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)/\1 ${args}/" "$grub_config"
    else
      echo "GRUB_CMDLINE_LINUX=\"${args}\"" | sudo tee -a "$grub_config" > /dev/null
    fi
    changed=0
  fi

  return $changed
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# SELinux in enforcing mode blocks the Izuma kubelet's bind mounts and the
# kube-router CNI plugin.
#
# Two states matter, and they can disagree. `getenforce` reports the running
# mode, but /etc/selinux/config decides the mode after the next reboot -- and
# installing Docker pulls in container-selinux + selinux-policy-targeted, which
# can turn a host that booted with SELinux disabled into one that comes back up
# Enforcing. Check both.
#
# Set SELINUX_SET_PERMISSIVE=1 to have this script apply the change itself
# instead of only reporting it.
check_selinux() {
  [ "$PKG_FAMILY" = "rhel" ] || return 0
  command -v getenforce >/dev/null 2>&1 || return 0

  local running config_mode="" config="/etc/selinux/config"
  running="$(getenforce 2>/dev/null || echo Disabled)"
  [ -r "$config" ] && config_mode="$(awk -F= '/^SELINUX=/ {print $2}' "$config" | tr -d '[:space:]')"

  log "SELinux is ${running} (on-disk setting: ${config_mode:-unknown})"

  local needs_fix=0
  [ "$running" = "Enforcing" ] && needs_fix=1
  [ "$config_mode" = "enforcing" ] && needs_fix=1
  [ "$needs_fix" = "1" ] || return 0

  if [ "$running" != "Enforcing" ] && [ "$config_mode" = "enforcing" ]; then
    warn "SELinux is not enforcing right now, but ${config} will make it Enforcing after the next reboot."
  fi

  warn "The Izuma kubelet and the kube-router CNI ship no SELinux policy, so container"
  warn "startup and CNI setup are denied under an enforcing policy."

  if [ "${SELINUX_SET_PERMISSIVE:-0}" = "1" ]; then
    log "SELINUX_SET_PERMISSIVE=1, switching SELinux to permissive"
    sudo setenforce 0 2>/dev/null || true
    if [ -w "$config" ] || [ "$(id -u)" = "0" ] || command -v sudo >/dev/null 2>&1; then
      sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' "$config" \
        || warn "Could not update ${config}"
    fi
    log "SELinux is now $(getenforce 2>/dev/null), on-disk setting: $(awk -F= '/^SELINUX=/ {print $2}' "$config" 2>/dev/null | tr -d '[:space:]')"
  else
    warn "Set it to permissive before continuing:"
    warn "    sudo setenforce 0"
    warn "    sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' ${config}"
    warn "  (or re-run this script with SELINUX_SET_PERMISSIVE=1)"
  fi
}

# firewalld's default zone drops the traffic kube-router and CoreDNS need.
check_firewalld() {
  [ "$PKG_FAMILY" = "rhel" ] || return 0
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active. It will block CoreDNS (172.21.2.1:53) and kube-router traffic."
    warn "Either stop it, or trust the kube-bridge and docker interfaces:"
    warn "    sudo firewall-cmd --permanent --zone=trusted --add-interface=kube-bridge"
    warn "    sudo firewall-cmd --permanent --zone=trusted --add-interface=docker0"
    warn "    sudo firewall-cmd --reload"
  else
    log "firewalld is not active"
  fi
}
