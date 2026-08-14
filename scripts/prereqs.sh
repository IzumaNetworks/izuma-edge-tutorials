#!/bin/bash

set -e

# Install Docker, curl and other utilities
# ipset is required for kube-router
echo "🔧 Updating package lists..."
sudo apt update

echo "📦 Installing required packages..."
sudo apt install -y \
    ca-certificates \
    curl \
    jq \
    bc \
    gnupg \
    lsb-release \
    wget \
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
# Highest Engine API version the kubelet's docker client can speak
KUBELET_DOCKER_API="1.38"

# Version of docker-ce currently installed, empty if not installed
docker_installed_version() {
    dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true
}

# 5:28.5.2-1~ubuntu.22.04~jammy -> 28
docker_major() {
    echo "${1#*:}" | cut -d. -f1
}

# Newest docker-ce/docker-ce-cli version in the repo matching DOCKER_MAJOR_PIN
resolve_pinned_docker_version() {
    apt-cache madison "$1" 2>/dev/null \
        | awk -v pin="$DOCKER_MAJOR_PIN" '$3 ~ ("^[0-9]+:" pin "\\.") { print $3; exit }'
}

# True when every package in $DOCKER_PACKAGES is fully installed
docker_components_installed() {
    local pkg
    for pkg in $DOCKER_PACKAGES; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "^install ok installed$"; then
            return 1
        fi
    done
    return 0
}

setup_docker_repo() {
    # Create the keyrings directory
    sudo install -m 0755 -d /etc/apt/keyrings

    # Download and add Docker's official GPG key
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        echo "📥 Downloading Docker GPG key..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    else
        echo "✅ Docker GPG key already exists, skipping download"
    fi

    # Set correct permissions
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Get the Ubuntu codename for the repository
    UBUNTU_CODENAME=$(lsb_release -cs)
    echo "📋 Detected Ubuntu codename: $UBUNTU_CODENAME"

    if [ "$UBUNTU_CODENAME" = "noble" ]; then
        echo "✅ Ubuntu 24.04 (noble) detected"
        DOCKER_CODENAME="noble"
    elif [ "$UBUNTU_CODENAME" = "jammy" ]; then
        echo "✅ Ubuntu 22.04 (jammy) detected"
        DOCKER_CODENAME="jammy"
    elif [ "$UBUNTU_CODENAME" = "focal" ]; then
        echo "✅ Ubuntu 20.04 (focal) detected"
        DOCKER_CODENAME="focal"
    else
        echo "⚠️  Unknown Ubuntu version: $UBUNTU_CODENAME"
        echo "🔧 Using 'jammy' as fallback (Ubuntu 22.04 repository)"
        DOCKER_CODENAME="jammy"
    fi

    echo "📋 Using Docker repository for: $DOCKER_CODENAME"

    # Add the Docker repository if it doesn't exist
    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo \
          "deb [arch=$(dpkg --print-architecture) \
          signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/ubuntu \
          $DOCKER_CODENAME stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    else
        echo "✅ Docker repository already exists, skipping addition"
    fi

    echo "🔄 Updating package lists with Docker repository..."
    sudo apt update
}

install_pinned_docker() {
    local version_ce version_cli
    version_ce=$(resolve_pinned_docker_version docker-ce)
    version_cli=$(resolve_pinned_docker_version docker-ce-cli)

    if [ -z "$version_ce" ] || [ -z "$version_cli" ]; then
        echo "❌ No Docker ${DOCKER_MAJOR_PIN}.x package available for $DOCKER_CODENAME."
        echo "   Versions offered by the Docker repository:"
        apt-cache madison docker-ce | awk '{print "     " $3}' | head -n 15
        echo "   Re-run with DOCKER_MAJOR_PIN set to a major from that list"
        echo "   (must be 28 or lower for kubelet API v${KUBELET_DOCKER_API} support)."
        exit 1
    fi

    # Release any hold from a previous run so apt is allowed to change these
    sudo apt-mark unhold docker-ce docker-ce-cli >/dev/null 2>&1 || true

    echo "🐳 Installing Docker $version_ce (pinned for kubelet Engine API v${KUBELET_DOCKER_API})..."
    sudo apt install -y --allow-downgrades \
        docker-ce="$version_ce" \
        docker-ce-cli="$version_cli" \
        containerd.io docker-buildx-plugin docker-compose-plugin

    echo "📌 Holding docker-ce and docker-ce-cli so 'apt upgrade' cannot pull in Docker 29.x..."
    sudo apt-mark hold docker-ce docker-ce-cli
}

# Confirm the running daemon actually accepts the kubelet's API version
verify_docker_api_version() {
    local min_api
    if ! sudo docker version >/dev/null 2>&1; then
        echo "⚠️  Could not reach the Docker daemon; skipping API version check."
        return 0
    fi

    min_api=$(sudo docker version --format '{{.Server.MinAPIVersion}}' 2>/dev/null || true)
    if [ -z "$min_api" ]; then
        echo "⚠️  Could not read the daemon's minimum API version; skipping check."
        return 0
    fi

    if [ "$(printf '%s\n%s\n' "$min_api" "$KUBELET_DOCKER_API" | sort -V | head -n1)" = "$min_api" ]; then
        echo "✅ Docker daemon minimum API version is $min_api (kubelet needs v${KUBELET_DOCKER_API}) "
    else
        echo "❌ Docker daemon minimum API version is $min_api, but the kubelet only speaks v${KUBELET_DOCKER_API}."
        echo "   The kubelet will fail with 'client version ${KUBELET_DOCKER_API} is too old'."
        echo "   Re-run with a lower DOCKER_MAJOR_PIN (e.g. DOCKER_MAJOR_PIN=27)."
        exit 1
    fi
}

echo "🔑 Setting up Docker repository..."
setup_docker_repo

INSTALLED_DOCKER_VERSION=$(docker_installed_version)
if [ -n "$INSTALLED_DOCKER_VERSION" ]; then
    echo "📋 Current Docker version: $INSTALLED_DOCKER_VERSION"
fi

if [ -n "$INSTALLED_DOCKER_VERSION" ] \
   && [ "$(docker_major "$INSTALLED_DOCKER_VERSION")" = "$DOCKER_MAJOR_PIN" ] \
   && docker_components_installed; then
    echo "✅ Docker ${DOCKER_MAJOR_PIN}.x and all components are already installed"
    sudo apt-mark hold docker-ce docker-ce-cli >/dev/null 2>&1 || true
else
    if [ -n "$INSTALLED_DOCKER_VERSION" ] \
       && [ "$(docker_major "$INSTALLED_DOCKER_VERSION")" != "$DOCKER_MAJOR_PIN" ]; then
        echo "⚠️  Installed Docker major $(docker_major "$INSTALLED_DOCKER_VERSION") is not the pinned major $DOCKER_MAJOR_PIN"
        echo "🔧 Docker 29.x rejects the kubelet's Engine API v${KUBELET_DOCKER_API} client, switching to ${DOCKER_MAJOR_PIN}.x..."
    fi
    install_pinned_docker
fi

echo "👤 Ensuring user is in docker group..."
sudo usermod -aG docker $USER

verify_docker_api_version

# Enable cgroup v1 <-- A requirement for Izuma Edge components
echo "🔧 Configuring cgroup v1 settings for Izuma Edge..."
GRUB_CONFIG="/etc/default/grub"
BACKUP_FILE="/etc/default/grub.bak"

# Check current cgroup version
echo "🔍 Checking current cgroup version..."
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    echo "📋 System is using cgroup v2"
    CGROUP_VERSION="v2"
else
    echo "📋 System is using cgroup v1"
    CGROUP_VERSION="v1"
fi

# Only configure cgroup v1 if system is not already using v1
if [ "$CGROUP_VERSION" = "v2" ]; then
    echo "🔧 Backing up GRUB config to $BACKUP_FILE..."
    sudo cp $GRUB_CONFIG $BACKUP_FILE

    echo "🔍 Checking if cgroup v1 flag is already present in GRUB..."
    if grep -q "systemd.unified_cgroup_hierarchy=0" "$GRUB_CONFIG"; then
        echo "✅ cgroup v1 flag is already enabled in GRUB config."
    else
        echo "⚙️  Adding cgroup v1 flag to GRUB_CMDLINE_LINUX_DEFAULT..."
        
        # Check if GRUB_CMDLINE_LINUX_DEFAULT exists and has content
        if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_CONFIG"; then
            # Add to existing GRUB_CMDLINE_LINUX_DEFAULT
            sudo sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)/\1 systemd.unified_cgroup_hierarchy=0/' "$GRUB_CONFIG"
        else
            # Create new GRUB_CMDLINE_LINUX_DEFAULT line
            echo 'GRUB_CMDLINE_LINUX_DEFAULT="systemd.unified_cgroup_hierarchy=0"' | sudo tee -a "$GRUB_CONFIG"
        fi
        
        echo "📋 Updated GRUB configuration:"
        sudo cat "$GRUB_CONFIG"

        echo "🔄 Updating GRUB..."
        sudo update-grub

        echo "✅ Docker installation and GRUB configuration completed."
        echo "📋 Summary:"
        echo "   - Docker pinned to ${DOCKER_MAJOR_PIN}.x (held) and user added to docker group"
        echo "   - cgroup v1 flag added to GRUB configuration"
        echo "   - GRUB updated"

        echo "⚠️  IMPORTANT: A reboot is required to apply the cgroup changes."
        echo "   After reboot, you can verify the changes with:"
        echo "   - 'docker --version' to check Docker installation"
        echo "   - 'stat -fc %T /sys/fs/cgroup' to verify cgroup v1 is active"

        read -p "🔁 Do you want to reboot now? (y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            echo "🔄 Rebooting in 5 seconds..."
            sleep 5
            sudo reboot
        else
            echo "🚨 Remember to reboot later to apply the cgroup changes."
            echo "   You can reboot manually with: sudo reboot"
        fi
    fi
else
    echo "✅ System is already using cgroup v1, no GRUB configuration needed."
    echo "✅ Docker installation completed."
    echo "📋 Summary:"
    echo "   - Docker pinned to ${DOCKER_MAJOR_PIN}.x (held) and user added to docker group"
    echo "   - System already using cgroup v1"

    echo "ℹ️  You can verify the installation with:"
    echo "   - 'docker --version' to check Docker installation"
    echo "   - 'stat -fc %T /sys/fs/cgroup' to verify cgroup v1 is active"
fi

echo ""
echo "📌 docker-ce and docker-ce-cli are held at ${DOCKER_MAJOR_PIN}.x because the Izuma Edge"
echo "   kubelet only speaks Docker Engine API v${KUBELET_DOCKER_API}, which Docker 29.x refuses."
echo "   To lift the hold later (not recommended while running KaaS):"
echo "     sudo apt-mark unhold docker-ce docker-ce-cli"
echo "ℹ️  If the kubelet was already failing on a newer Docker, restart it now:"
echo "     sudo systemctl restart docker kubelet"