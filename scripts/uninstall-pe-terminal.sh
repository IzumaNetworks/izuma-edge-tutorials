#!/usr/bin/env bash

# Uninstall script for Izuma Edge pe-terminal.
# Removes the pe-terminal service and package.
#
# Default behavior is DRY-RUN (prints what would be removed).
# Use --force to apply changes.

set -euo pipefail

DRY_RUN=1

SERVICES=(
  pe-terminal
)

PACKAGES=(
  pe-terminal
)

usage() {
  cat <<'EOF'
Usage:
  ./scripts/uninstall-pe-terminal.sh [--force] [--help]

Options:
  --force   Apply deletions. Without this flag, script runs in dry-run mode.
  --help    Show this help message.

Examples:
  ./scripts/uninstall-pe-terminal.sh
  ./scripts/uninstall-pe-terminal.sh --force
EOF
}

log() {
  echo "[uninstall] $*"
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

cleanup_services() {
  log "Stopping and disabling services"
  for svc in "${SERVICES[@]}"; do
    run "sudo systemctl stop \"$svc\" 2>/dev/null || true"
    run "sudo systemctl disable \"$svc\" 2>/dev/null || true"
    run "sudo systemctl reset-failed \"$svc\" 2>/dev/null || true"
  done
  run "sudo systemctl daemon-reload"
}

cleanup_packages() {
  log "Purging pe-terminal package"
  for pkg in "${PACKAGES[@]}"; do
    run "sudo apt-get purge -y \"$pkg\" 2>/dev/null || true"
  done
  run "sudo apt-get autoremove -y || true"
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
  require_cmd apt-get

  if [ "$DRY_RUN" -eq 1 ]; then
    warn "Running in DRY-RUN mode. No changes will be made."
    warn "Re-run with --force to apply uninstall."
  else
    log "Running in FORCE mode. Uninstall will be applied."
  fi

  cleanup_services
  cleanup_packages

  log "Uninstall complete."
}

main "$@"
