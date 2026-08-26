#!/usr/bin/env bash

# Prerequisites for Izuma Edge.
#
# Supported hosts:
#   - Ubuntu 20.04 / 22.04 / 24.04
#   - AlmaLinux 9, Rocky Linux 9, RHEL 9, CentOS Stream 9
#
# Installs Docker (pinned to a major the Izuma kubelet can talk to) plus the
# common utilities the other scripts need, and switches the host to the
# cgroup v1 hierarchy that the Izuma Edge kubelet requires.
#
# Environment overrides:
#   DOCKER_MAJOR_PIN=27   install a different Docker major (must be <= 28)
#   REBOOT_MODE=yes|no|ask  what to do once the cgroup change is staged
#                           (default: ask, or "no" when stdin is not a terminal)
#   SELINUX_SET_PERMISSIVE=0  keep the host's current SELinux setting. The
#                             default is to set SELinux permissive, because
#                             Izuma Edge ships no SELinux policy and a host that
#                             reboots into Enforcing can come back unreachable.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "$*"; }
warn() { echo "⚠️  $*" >&2; }
die()  { echo "❌ $*" >&2; exit 1; }

# shellcheck source=lib/distro.sh
. "${SCRIPT_DIR}/lib/distro.sh"

detect_distro
echo "🖥️  Detected ${DISTRO_ID} ${DISTRO_VERSION_ID} (${PKG_FAMILY} package family, ${PKG_ARCH})"

# ---------------------------------------------------------------------------
# Base packages
#
# Named with their Debian names; lib/distro.sh maps them to RHEL equivalents.
# ipset is required by kube-router.
# ---------------------------------------------------------------------------
echo "🔧 Updating package lists..."
pkg_refresh

echo "📦 Installing required packages..."
pkg_install \
    ca-certificates \
    curl \
    jq \
    bc \
    gnupg \
    lsb-release \
    wget \
    tar \
    gzip \
    netcat-openbsd \
    procps \
    ipset \
    python3 \
    python3-pip \
    build-essential \
    net-tools \
    telnet \
    dnsutils \
    apt-transport-https \
    software-properties-common

# ---------------------------------------------------------------------------
# Docker version pin
#
# KaaS is built on Kubernetes 1.13.2, and that kubelet talks to the Docker
# daemon with a client that speaks Engine API v1.38. Docker Engine 29.0 dropped
# support for every API version below 1.44 (29.3+ walked it back to 1.40), so a
# 29.x daemon rejects the kubelet outright:
#
#   failed to run Kubelet: failed to create kubelet: failed to get docker
#   version: Error response from daemon: client version 1.38 is too old.
#   Minimum supported API version is 1.40
#
# Docker Engine 28.5 and older still accept API 1.24 and up, so we pin to the
# newest 28.x and hold the packages. Setting DOCKER_MIN_API_VERSION on a 29.x
# daemon does NOT help - the pre-1.40 API code paths were removed, not gated.
#
# API version matrix: https://docs.docker.com/reference/api/engine/
#
# Override with e.g. DOCKER_MAJOR_PIN=27 ./prereqs.sh if 28.x ever misbehaves.
# ---------------------------------------------------------------------------
DOCKER_MAJOR_PIN="${DOCKER_MAJOR_PIN:-28}"
DOCKER_PACKAGES="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
DOCKER_HELD_PACKAGES="docker-ce docker-ce-cli"
# Highest Engine API version the kubelet's docker client can speak
KUBELET_DOCKER_API="1.38"

# 5:28.5.2-1~ubuntu.22.04~jammy -> 28,  3:28.5.2-1.el9 -> 28
docker_major() {
    echo "${1#*:}" | cut -d. -f1
}

# True when every package in $DOCKER_PACKAGES is fully installed
docker_components_installed() {
    local pkg
    for pkg in $DOCKER_PACKAGES; do
        pkg_is_installed "$pkg" || return 1
    done
    return 0
}

install_pinned_docker() {
    local version_ce version_cli
    version_ce=$(pkg_available_version_for_major docker-ce "$DOCKER_MAJOR_PIN")
    version_cli=$(pkg_available_version_for_major docker-ce-cli "$DOCKER_MAJOR_PIN")

    if [ -z "$version_ce" ] || [ -z "$version_cli" ]; then
        echo "❌ No Docker ${DOCKER_MAJOR_PIN}.x package available for ${DISTRO_ID} ${DISTRO_VERSION_ID}."
        echo "   Versions offered by the Docker repository:"
        pkg_available_versions docker-ce | head -n 15 | sed 's/^/     /'
        echo "   Re-run with DOCKER_MAJOR_PIN set to a major from that list"
        echo "   (must be 28 or lower for kubelet API v${KUBELET_DOCKER_API} support)."
        exit 1
    fi

    # Release any hold from a previous run so the package manager may change these
    pkg_unhold $DOCKER_HELD_PACKAGES

    echo "🐳 Installing Docker $version_ce (pinned for kubelet Engine API v${KUBELET_DOCKER_API})..."
    pkg_install_versioned \
        "docker-ce=${version_ce}" \
        "docker-ce-cli=${version_cli}"
    pkg_install containerd.io docker-buildx-plugin docker-compose-plugin

    echo "📌 Holding docker-ce and docker-ce-cli so an upgrade cannot pull in Docker 29.x..."
    pkg_hold $DOCKER_HELD_PACKAGES
}

# On RHEL derivatives dnf does not start a service after installing it.
ensure_docker_running() {
    echo "🚀 Enabling and starting the Docker daemon..."
    sudo systemctl enable --now docker || warn "Could not enable/start docker.service"

    local waited=0
    while ! sudo docker info >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 30 ]; then
            warn "Docker daemon did not become ready within 30s."
            warn "Check it with: sudo systemctl status docker; sudo journalctl -u docker -n 100"
            return 0
        fi
    done
    echo "✅ Docker daemon is running"
}

# Confirm the running daemon actually accepts the kubelet's API version
verify_docker_api_version() {
    local min_api
    if ! sudo docker version >/dev/null 2>&1; then
        warn "Could not reach the Docker daemon; skipping API version check."
        return 0
    fi

    min_api=$(sudo docker version --format '{{.Server.MinAPIVersion}}' 2>/dev/null || true)
    if [ -z "$min_api" ]; then
        warn "Could not read the daemon's minimum API version; skipping check."
        return 0
    fi

    if [ "$(printf '%s\n%s\n' "$min_api" "$KUBELET_DOCKER_API" | sort -V | head -n1)" = "$min_api" ]; then
        echo "✅ Docker daemon minimum API version is $min_api (kubelet needs v${KUBELET_DOCKER_API})"
    else
        echo "❌ Docker daemon minimum API version is $min_api, but the kubelet only speaks v${KUBELET_DOCKER_API}."
        echo "   The kubelet will fail with 'client version ${KUBELET_DOCKER_API} is too old'."
        echo "   Re-run with a lower DOCKER_MAJOR_PIN (e.g. DOCKER_MAJOR_PIN=27)."
        exit 1
    fi
}

echo "🔑 Setting up Docker repository..."
setup_docker_repo

INSTALLED_DOCKER_VERSION=$(pkg_installed_version docker-ce)
if [ -n "$INSTALLED_DOCKER_VERSION" ]; then
    echo "📋 Current Docker version: $INSTALLED_DOCKER_VERSION"
fi

if [ -n "$INSTALLED_DOCKER_VERSION" ] \
   && [ "$(docker_major "$INSTALLED_DOCKER_VERSION")" = "$DOCKER_MAJOR_PIN" ] \
   && docker_components_installed; then
    echo "✅ Docker ${DOCKER_MAJOR_PIN}.x and all components are already installed"
    pkg_hold $DOCKER_HELD_PACKAGES
else
    if [ -n "$INSTALLED_DOCKER_VERSION" ] \
       && [ "$(docker_major "$INSTALLED_DOCKER_VERSION")" != "$DOCKER_MAJOR_PIN" ]; then
        warn "Installed Docker major $(docker_major "$INSTALLED_DOCKER_VERSION") is not the pinned major $DOCKER_MAJOR_PIN"
        echo "🔧 Docker 29.x rejects the kubelet's Engine API v${KUBELET_DOCKER_API} client, switching to ${DOCKER_MAJOR_PIN}.x..."
    fi
    install_pinned_docker
fi

echo "👤 Ensuring user is in docker group..."
sudo groupadd -f docker
sudo usermod -aG docker "${SUDO_USER:-$USER}"

ensure_docker_running
verify_docker_api_version

# ---------------------------------------------------------------------------
# Host policy checks (RHEL derivatives only; no-ops elsewhere)
# ---------------------------------------------------------------------------
echo "🔍 Checking host security policy..."
check_selinux
check_firewalld

# ---------------------------------------------------------------------------
# cgroup v1 <-- a requirement for the Izuma Edge kubelet
#
# Both Ubuntu 22.04+ and RHEL 9 boot the unified (v2) hierarchy by default.
# systemd.unified_cgroup_hierarchy=0 puts systemd back on the legacy
# hierarchy; systemd.legacy_systemd_cgroup_controller makes it mount the
# named "systemd" controller the old way as well, which RHEL 9 needs.
# ---------------------------------------------------------------------------
CGROUP_ARGS="systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller"
REBOOT_MODE="${REBOOT_MODE:-ask}"

echo "🔧 Configuring cgroup v1 for Izuma Edge..."
echo "🔍 Checking current cgroup version..."
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    echo "📋 System is using cgroup v2"
    CGROUP_VERSION="v2"
else
    echo "📋 System is using cgroup v1"
    CGROUP_VERSION="v1"
fi

summary_docker() {
    echo "   - Docker pinned to ${DOCKER_MAJOR_PIN}.x (held) and user added to the docker group"
    if [ "${SELINUX_WAS_CHANGED:-0}" = "1" ]; then
        echo "   - SELinux set to permissive (running mode and /etc/selinux/config)"
    fi
}

if [ "$CGROUP_VERSION" = "v1" ]; then
    echo "✅ System is already using cgroup v1, no bootloader change needed."
    echo "✅ Docker installation completed."
    echo "📋 Summary:"
    summary_docker
    echo "   - System already using cgroup v1"
else
    # The kernel must actually still carry the v1 controllers. RHEL 9 keeps
    # them compiled in but deprecated, so verify rather than assume.
    if [ -r /proc/cgroups ] && ! awk 'NR>1 && $4=="1" {found=1} END {exit !found}' /proc/cgroups; then
        die "This kernel reports no enabled cgroup v1 controllers in /proc/cgroups; it cannot boot the legacy hierarchy."
    fi

    if bootloader_add_cmdline_args $CGROUP_ARGS; then
        echo "✅ Docker installation and bootloader configuration completed."
        echo "📋 Summary:"
        summary_docker
        echo "   - Kernel arguments added: ${CGROUP_ARGS}"

        echo ""
        if [ "${SELINUX_WAS_CHANGED:-0}" = "1" ]; then
            echo "⚠️  NOTE: SELinux was set to permissive by this script. That takes"
            echo "   effect on the reboot below and is what keeps the host reachable."
        fi
        echo "⚠️  IMPORTANT: A reboot is required to apply the cgroup change."
        echo "   After reboot, verify with:"
        echo "   - 'docker --version'"
        echo "   - 'stat -fc %T /sys/fs/cgroup'  (expect 'tmpfs' for v1, 'cgroup2fs' for v2)"

        case "$REBOOT_MODE" in
            yes)
                echo "🔄 REBOOT_MODE=yes, rebooting in 5 seconds..."
                sleep 5
                sudo reboot
                ;;
            no)
                echo "🚨 REBOOT_MODE=no. Reboot later to apply the cgroup change: sudo reboot"
                ;;
            *)
                if [ -t 0 ]; then
                    read -r -p "🔁 Do you want to reboot now? (y/N): " choice
                    if [[ "$choice" =~ ^[Yy]$ ]]; then
                        echo "🔄 Rebooting in 5 seconds..."
                        sleep 5
                        sudo reboot
                    else
                        echo "🚨 Remember to reboot later: sudo reboot"
                    fi
                else
                    echo "🚨 Not running on a terminal, so not prompting to reboot."
                    echo "   Reboot to apply the cgroup change: sudo reboot"
                    echo "   (or re-run with REBOOT_MODE=yes to reboot automatically)"
                fi
                ;;
        esac
    else
        echo "✅ cgroup v1 kernel arguments were already configured."
        echo "🚨 The running system is still on cgroup v2 - reboot to apply: sudo reboot"
    fi
fi

echo ""
echo "📌 docker-ce and docker-ce-cli are held at ${DOCKER_MAJOR_PIN}.x because the Izuma Edge"
echo "   kubelet only speaks Docker Engine API v${KUBELET_DOCKER_API}, which Docker 29.x refuses."
echo "   To lift the hold later (not recommended while running KaaS):"
echo "     $(pkg_unhold_hint $DOCKER_HELD_PACKAGES)"
echo "ℹ️  If the kubelet was already failing on a newer Docker, restart it now:"
echo "     sudo systemctl restart docker kubelet"
