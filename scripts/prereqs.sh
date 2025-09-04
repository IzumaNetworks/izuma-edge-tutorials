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

echo "🔑 Setting up Docker repository..."
# Check if Docker is already installed
if command -v docker >/dev/null 2>&1; then
    echo "✅ Docker is already installed"
    DOCKER_VERSION=$(docker --version)
    echo "📋 Current Docker version: $DOCKER_VERSION"
    
    # Check if all required Docker components are installed
    echo "🔍 Checking Docker components..."
    MISSING_PACKAGES=""
    
    # Check each package individually
    if ! dpkg -l | grep -q "docker-ce "; then
        MISSING_PACKAGES="$MISSING_PACKAGES docker-ce"
    fi
    if ! dpkg -l | grep -q "docker-ce-cli"; then
        MISSING_PACKAGES="$MISSING_PACKAGES docker-ce-cli"
    fi
    if ! dpkg -l | grep -q "containerd.io"; then
        MISSING_PACKAGES="$MISSING_PACKAGES containerd.io"
    fi
    if ! dpkg -l | grep -q "docker-buildx-plugin"; then
        MISSING_PACKAGES="$MISSING_PACKAGES docker-buildx-plugin"
    fi
    if ! dpkg -l | grep -q "docker-compose-plugin"; then
        MISSING_PACKAGES="$MISSING_PACKAGES docker-compose-plugin"
    fi
    
    if [ -n "$MISSING_PACKAGES" ]; then
        echo "⚠️  Missing Docker components:$MISSING_PACKAGES"
        echo "🔧 Installing missing components..."
        
        # Set up Docker repository if needed
        sudo install -m 0755 -d /etc/apt/keyrings
        
        if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            echo "📥 Downloading Docker GPG key..."
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
                sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        fi
        
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Get the Ubuntu codename for the repository
        UBUNTU_CODENAME=$(lsb_release -cs)
        echo "📋 Detected Ubuntu codename: $UBUNTU_CODENAME"
        
        # Handle Ubuntu versions
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
        
        # Add the Docker repository if it doesn't exist
        if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
            echo \
              "deb [arch=$(dpkg --print-architecture) \
              signed-by=/etc/apt/keyrings/docker.gpg] \
              https://download.docker.com/linux/ubuntu \
              $DOCKER_CODENAME stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        fi
        
        echo "🔄 Updating package lists..."
        sudo apt update
        
        echo "📦 Installing missing Docker components..."
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        echo "✅ All Docker components are already installed"
    fi
    
    echo "👤 Ensuring user is in docker group..."
    sudo usermod -aG docker $USER
else
    echo "🐳 Docker not found, proceeding with installation..."
    
    # Create the keyrings directory
    sudo install -m 0755 -d /etc/apt/keyrings

    # Download and add Docker's official GPG key
    echo "📥 Downloading Docker GPG key..."
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
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

    # Handle Ubuntu 24.04 specifically (noble)
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

    echo "🐳 Installing Docker..."
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo "👤 Adding user to docker group..."
    sudo usermod -aG docker $USER
fi

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
        echo "   - Docker installed and user added to docker group"
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
    echo "   - Docker installed and user added to docker group"
    echo "   - System already using cgroup v1"
    
    echo "ℹ️  You can verify the installation with:"
    echo "   - 'docker --version' to check Docker installation"
    echo "   - 'stat -fc %T /sys/fs/cgroup' to verify cgroup v1 is active"
fi