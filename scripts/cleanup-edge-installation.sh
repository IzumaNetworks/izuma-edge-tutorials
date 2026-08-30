#!/usr/bin/env bash

# Cleanup script for Izuma Edge tutorial environment.
# Removes thick-edge services/packages and Docker artifacts.
#
# Supported hosts: Ubuntu 20.04/22.04/24.04 and AlmaLinux/Rocky/RHEL 9.
#
# Default behavior is DRY-RUN (prints what would be removed).
# Use --force to apply changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=1

SERVICES=(
  edge-proxy
  kubelet
  kube-router
  coredns
  wait-for-pelion-identity
)

PACKAGES=(
  pe-utils
  edge-proxy
  containernetworking-plugins-c2d
  kubelet
)

UNIT_FILES=(
  /etc/systemd/system/kube-router.service
  /etc/systemd/system/coredns.service
  /etc/systemd/system/wait-for-pelion-identity.service
)

PATHS_TO_REMOVE=(
  /var/lib/pelion/mbed/mcc_config
  /var/lib/pelion/mbed/ec-kcm-conf
  /var/lib/pelion/mbed
  /var/lib/kubelet
  /var/lib/cni
  /etc/cni
  /etc/kubernetes
  /tmp/edge.sock
  /etc/modules-load.d/izuma-edge.conf
  /etc/sysctl.d/99-izuma-edge.conf
  /etc/NetworkManager/conf.d/99-izuma-edge-unmanaged.conf
  /etc/pelion/node-labels
  /usr/bin/izuma-node-labels
  /usr/bin/launch-kubelet.sh.izuma-orig
)

usage() {
  cat <<'EOF'
Usage:
  ./scripts/cleanup-edge-installation.sh [--force] [--help]

Options:
  --force   Apply deletions. Without this flag, script runs in dry-run mode.
  --help    Show this help message.

Examples:
  ./scripts/cleanup-edge-installation.sh
  ./scripts/cleanup-edge-installation.sh --force
EOF
}

log() {
  echo "[cleanup] $*"
}

warn() {
  echo "[warn] $*" >&2
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || warn "Command '$1' not found; related cleanup may be skipped."
}

# shellcheck source=lib/distro.sh
. "${SCRIPT_DIR}/lib/distro.sh"

cleanup_services() {
  log "Stopping and disabling services"
  for svc in "${SERVICES[@]}"; do
    run "sudo systemctl stop \"$svc\" 2>/dev/null || true"
    run "sudo systemctl disable \"$svc\" 2>/dev/null || true"
    run "sudo systemctl reset-failed \"$svc\" 2>/dev/null || true"
  done

  log "Removing custom unit files"
  for unit_file in "${UNIT_FILES[@]}"; do
    run "sudo rm -f \"$unit_file\""
  done
  run "sudo systemctl daemon-reload"
}

cleanup_packages() {
  log "Purging installed edge packages"
  for pkg in "${PACKAGES[@]}"; do
    run "pkg_purge \"$pkg\""
  done
  run "pkg_autoremove"
}

cleanup_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found; skipping Docker cleanup."
    return 0
  fi

  log "Removing all Docker containers"
  run "docker ps -aq | xargs -r docker rm -f"

  log "Removing all Docker images"
  run "docker images -aq | xargs -r docker rmi -f"

  log "Removing all Docker volumes"
  run "docker volume ls -q | xargs -r docker volume rm -f"

  log "Pruning custom Docker networks"
  run "docker network prune -f"

  log "Final Docker prune (images/build cache/volumes)"
  run "docker system prune -a --volumes -f"
}

cleanup_files() {
  log "Removing local edge/kubernetes runtime paths"
  for p in "${PATHS_TO_REMOVE[@]}"; do
    run "sudo rm -rf \"$p\""
  done
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        DRY_RUN=0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done

  require_cmd sudo
  require_cmd systemctl

  detect_distro
  log "Detected ${DISTRO_ID} ${DISTRO_VERSION_ID} (${PKG_FAMILY} family)"

  if [ "$DRY_RUN" -eq 1 ]; then
    warn "Running in DRY-RUN mode. No changes will be made."
    warn "Re-run with --force to apply cleanup."
  else
    log "Running in FORCE mode. Cleanup will be applied."
  fi

  cleanup_services
  cleanup_packages
  cleanup_docker
  cleanup_files

  log "Cleanup complete."
}

main "$@"
