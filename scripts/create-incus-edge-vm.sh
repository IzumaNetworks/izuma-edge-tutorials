#!/usr/bin/env bash

# Create an Incus VM and provision it as an Izuma Edge device, end to end.
#
# This drives the other scripts in this directory inside a freshly launched
# Incus virtual machine:
#   1. incus launch  - create the VM
#   2. prereqs.sh    - install Docker, switch to cgroup v1, reboot
#   3. run-edge-core.sh              - always (every device needs Edge Core)
#   4. install-thick-edge-services.sh - only for the "full" profile
#
# Run this on the HOST that has the `incus` client configured (local daemon
# or a configured remote), not inside the VM.
#
# Usage:
#   ./scripts/create-incus-edge-vm.sh [options]
#
# Options:
#   --environment staging|production   Target environment (default: prompt)
#   --profile edge-core|full           edge-core only, or edge-core + thick
#                                       edge services (default: prompt)
#   --os ubuntu-22.04                  Guest OS. Only value supported today.
#   --name <name>                      VM name (default: generated)
#   --remote <remote>                  Incus image remote (default: images)
#   --cpu <n>                          vCPUs (default: profile-based)
#   --memory <GiB>                     Memory in GiB (default: profile-based)
#   --disk <GiB>                       Root disk in GiB (default: profile-based)
#   --account-id <id>                  Izuma Device Management account ID
#   --access-token <token>             Izuma Device Management access token
#   --yes                              Assume "yes" / don't prompt for
#                                       anything not given via flags or env
#   --help                             Show this help message
#
# Environment overrides (same names as the flags above, upper-cased):
#   ENVIRONMENT, PROFILE, OS, VM_NAME, VM_REMOTE, VM_CPU, VM_MEMORY_GB,
#   VM_DISK_GB, ACCOUNT_ID, ACCESS_TOKEN, ASSUME_YES=1
#
# Credentials: obtain ACCOUNT_ID and ACCESS_TOKEN from
# https://portal.mbedcloud.com (Team Configuration -> Account ID; Access
# Management -> Access Key -> New Access Key). Which portal account you log
# into is what determines staging vs. production - this script does not
# change that; --environment only affects the VM's sizing, name and tags so
# staging and production devices are easy to tell apart in `incus list`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUEST_REPO_DIR="/root/izuma-edge-tutorials"

log()  { echo "[create-vm] $*"; }
warn() { echo "[warn] $*" >&2; }
die()  { echo "[error] $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found on this host"
}

usage() {
  sed -n '3,43p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Defaults / option parsing
# ---------------------------------------------------------------------------
ENVIRONMENT="${ENVIRONMENT:-}"
PROFILE="${PROFILE:-}"
OS="${OS:-ubuntu-22.04}"
VM_NAME="${VM_NAME:-}"
VM_REMOTE="${VM_REMOTE:-images}"
VM_CPU="${VM_CPU:-}"
VM_MEMORY_GB="${VM_MEMORY_GB:-}"
VM_DISK_GB="${VM_DISK_GB:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"
ASSUME_YES="${ASSUME_YES:-0}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --environment)  ENVIRONMENT="${2:-}"; shift 2 ;;
    --profile)      PROFILE="${2:-}"; shift 2 ;;
    --os)           OS="${2:-}"; shift 2 ;;
    --name)         VM_NAME="${2:-}"; shift 2 ;;
    --remote)       VM_REMOTE="${2:-}"; shift 2 ;;
    --cpu)          VM_CPU="${2:-}"; shift 2 ;;
    --memory)       VM_MEMORY_GB="${2:-}"; shift 2 ;;
    --disk)         VM_DISK_GB="${2:-}"; shift 2 ;;
    --account-id)   ACCOUNT_ID="${2:-}"; shift 2 ;;
    --access-token) ACCESS_TOKEN="${2:-}"; shift 2 ;;
    --yes)          ASSUME_YES=1; shift ;;
    --help|-h)      usage; exit 0 ;;
    *)              die "Unknown argument: $1 (see --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Interactive selection helpers
# ---------------------------------------------------------------------------
# Only prompt when stdin is a terminal; a non-interactive run must supply
# everything via flags/env, same convention as prereqs.sh's REBOOT_MODE.
can_prompt() { [ -t 0 ] && [ "$ASSUME_YES" != "1" ]; }

prompt_choice() {
  # prompt_choice <var-name> <prompt> <opt1> <opt2> [...]
  local __var="$1" __prompt="$2"; shift 2
  local current
  current="$(eval "echo \${$__var:-}")"
  [ -n "$current" ] && return 0

  if ! can_prompt; then
    die "$__prompt not set. Pass it as a flag/env var, or run interactively (see --help)."
  fi

  echo "$__prompt"
  local PS3="#? "
  local choice
  select choice in "$@"; do
    if [ -n "$choice" ]; then
      eval "$__var=\"\$choice\""
      break
    fi
    echo "Invalid selection, try again."
  done
}

prompt_choice ENVIRONMENT "Which environment is this device for?" "staging" "production"
prompt_choice PROFILE     "Which services should this device run?" "edge-core" "full"

case "$ENVIRONMENT" in
  staging|production) : ;;
  *) die "--environment must be 'staging' or 'production' (got '$ENVIRONMENT')" ;;
esac

case "$PROFILE" in
  edge-core|full) : ;;
  *) die "--profile must be 'edge-core' or 'full' (got '$PROFILE')" ;;
esac

# "full" = edge-core (container) + thick edge services (edge-proxy, kubelet,
# kube-router, coredns, pe-terminal) installed natively on the host per
# install-thick-edge-services.sh.
case "$OS" in
  ubuntu-22.04) IMAGE_BASENAME="ubuntu/22.04" ;;
  *) die "Unsupported --os '$OS'. Only 'ubuntu-22.04' is supported for now." ;;
esac
IMAGE_SPEC="${VM_REMOTE}:${IMAGE_BASENAME}"

# ---------------------------------------------------------------------------
# Sizing per environment
#
# staging matches the spec this tutorial suite is validated against (2
# vCPU/2GiB/16GiB, see README.md). production gets more headroom since a real
# device also carries other workloads via KaaS. Either is overridable with
# --cpu/--memory/--disk.
# ---------------------------------------------------------------------------
case "$ENVIRONMENT" in
  staging)    DEFAULT_CPU=2; DEFAULT_MEM=2;  DEFAULT_DISK=16 ;;
  production) DEFAULT_CPU=4; DEFAULT_MEM=4;  DEFAULT_DISK=32 ;;
esac
VM_CPU="${VM_CPU:-$DEFAULT_CPU}"
VM_MEMORY_GB="${VM_MEMORY_GB:-$DEFAULT_MEM}"
VM_DISK_GB="${VM_DISK_GB:-$DEFAULT_DISK}"

if [ -z "$VM_NAME" ]; then
  VM_NAME="izuma-edge-${ENVIRONMENT}-${PROFILE}-$(date +%s)"
fi
# Incus instance names: letters, digits and hyphens only.
if ! [[ "$VM_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
  die "--name '$VM_NAME' is invalid; Incus instance names may only contain letters, digits and hyphens."
fi

# ---------------------------------------------------------------------------
# Credentials
#
# Both profiles run Edge Core, so both need these. Read with -s so the token
# never lands in shell history or gets echoed to the terminal; they are only
# ever passed to the guest as exec-time environment variables, never written
# to a file on the host.
# ---------------------------------------------------------------------------
if [ -z "$ACCOUNT_ID" ]; then
  can_prompt || die "ACCOUNT_ID not set. Pass --account-id (or ACCOUNT_ID env var)."
  read -r -p "Izuma Account ID (portal.mbedcloud.com -> Team Configuration -> Account ID): " ACCOUNT_ID
fi
if [ -z "$ACCESS_TOKEN" ]; then
  can_prompt || die "ACCESS_TOKEN not set. Pass --access-token (or ACCESS_TOKEN env var)."
  read -r -s -p "Izuma Access Token (portal.mbedcloud.com -> Access Management -> Access Key): " ACCESS_TOKEN
  echo ""
fi
if ! [[ "$ACCOUNT_ID" =~ ^[0-9a-fA-F]{32}$ ]] \
   && ! [[ "$ACCOUNT_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  die "ACCOUNT_ID must be a 32-character hex string or a UUID."
fi
[ -n "$ACCESS_TOKEN" ] || die "ACCESS_TOKEN is required."

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
require_cmd incus

if incus info "$VM_NAME" >/dev/null 2>&1; then
  die "An Incus instance named '$VM_NAME' already exists. Pick a different --name, or remove it first with: incus delete --force $VM_NAME"
fi

echo ""
log "Environment : $ENVIRONMENT"
log "Profile     : $PROFILE ($([ "$PROFILE" = "full" ] && echo "edge-core + thick edge services" || echo "edge-core only"))"
log "OS          : $OS ($IMAGE_SPEC)"
log "VM name     : $VM_NAME"
log "Sizing      : ${VM_CPU} vCPU, ${VM_MEMORY_GB}GiB RAM, ${VM_DISK_GB}GiB disk"
echo ""

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
launch_vm() {
  log "Launching '$VM_NAME' from $IMAGE_SPEC..."
  # security.secureboot=false: images.linuxcontainers.org VM images are not
  # signed with keys OVMF trusts, so secure boot must be off or the VM never
  # gets past the firmware.
  incus launch "$IMAGE_SPEC" "$VM_NAME" --vm \
    -c limits.cpu="$VM_CPU" \
    -c limits.memory="${VM_MEMORY_GB}GiB" \
    -c security.secureboot=false \
    -c user.izuma-edge-environment="$ENVIRONMENT" \
    -c user.izuma-edge-profile="$PROFILE" \
    -d root,size="${VM_DISK_GB}GiB"
}

wait_for_agent() {
  local timeout="${1:-180}" waited=0
  log "Waiting for the Incus agent in '$VM_NAME'..."
  while ! incus exec "$VM_NAME" -- true >/dev/null 2>&1; do
    sleep 3
    waited=$((waited + 3))
    if [ "$waited" -ge "$timeout" ]; then
      die "Incus agent in '$VM_NAME' did not come up within ${timeout}s. Inspect with: incus console $VM_NAME"
    fi
  done
}

wait_for_cloudinit() {
  log "Waiting for cloud-init to finish in '$VM_NAME'..."
  incus exec "$VM_NAME" -- cloud-init status --wait >/dev/null 2>&1 \
    || warn "cloud-init reported a non-zero status; continuing anyway"
}

push_scripts() {
  log "Copying tutorial scripts into '$VM_NAME'..."
  incus exec "$VM_NAME" -- mkdir -p "$GUEST_REPO_DIR"
  incus file push -r "${REPO_ROOT}/scripts" "${VM_NAME}${GUEST_REPO_DIR}/"
  incus exec "$VM_NAME" -- bash -lc "chmod +x ${GUEST_REPO_DIR}/scripts/*.sh"
}

# prereqs.sh reboots the VM once it configures cgroup v1. The `incus exec`
# call ends when the guest goes down for that reboot, so its exit status is
# not meaningful here - what matters is that the VM comes back with cgroup v1
# active, which is verified explicitly below.
run_prereqs() {
  log "Running prereqs.sh in '$VM_NAME' (installs Docker, switches to cgroup v1, then reboots)..."
  incus exec "$VM_NAME" -- env REBOOT_MODE=yes bash -lc "cd ${GUEST_REPO_DIR} && ./scripts/prereqs.sh" || true

  log "Waiting for '$VM_NAME' to reboot..."
  sleep 15
  wait_for_agent 240
  wait_for_cloudinit

  local cgroup_type
  cgroup_type="$(incus exec "$VM_NAME" -- stat -fc %T /sys/fs/cgroup 2>/dev/null || true)"
  case "$cgroup_type" in
    tmpfs) log "cgroup v1 confirmed active in '$VM_NAME'" ;;
    *) die "cgroup v1 was not active after reboot (got '$cgroup_type'). Inspect with: incus exec $VM_NAME -- bash" ;;
  esac
}

run_edge_core() {
  log "Provisioning Edge Core in '$VM_NAME'..."
  incus exec "$VM_NAME" \
    --env ACCOUNT_ID="$ACCOUNT_ID" \
    --env ACCESS_TOKEN="$ACCESS_TOKEN" \
    -- bash -lc "cd ${GUEST_REPO_DIR} && ./scripts/run-edge-core.sh"
}

run_thick_edge() {
  log "Installing thick edge services in '$VM_NAME'..."
  incus exec "$VM_NAME" -- bash -lc "cd ${GUEST_REPO_DIR} && ./scripts/install-thick-edge-services.sh"
}

print_summary() {
  echo ""
  log "✓ '$VM_NAME' is provisioned (${ENVIRONMENT}, profile: ${PROFILE})"
  incus list "$VM_NAME"
  echo ""
  log "Useful commands:"
  echo "  incus shell $VM_NAME"
  echo "  incus exec $VM_NAME -- docker logs edge-core"
  echo "  incus exec $VM_NAME -- curl -s localhost:9101/status"
  if [ "$PROFILE" = "full" ]; then
    echo "  incus exec $VM_NAME -- sudo edge-info -m"
  fi
  echo "  incus delete --force $VM_NAME   # tear it down"
}

on_failure() {
  local code=$?
  [ "$code" -eq 0 ] && return 0
  warn "Provisioning failed (exit $code). '$VM_NAME' was left running for inspection."
  warn "Delete it with: incus delete --force $VM_NAME"
}
trap on_failure EXIT

launch_vm
wait_for_agent
wait_for_cloudinit
push_scripts
run_prereqs
run_edge_core
[ "$PROFILE" = "full" ] && run_thick_edge
print_summary
