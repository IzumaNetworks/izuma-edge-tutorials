#!/usr/bin/env bash

# Start Edge Core (mbed-edge) in a Docker container.
#
# Edge Core is distributed as a container image, so this step is identical on
# Ubuntu and on AlmaLinux/Rocky/RHEL 9. The script exists so the credentials
# are not pasted into a shell history and so the flags stay consistent.
#
# Usage:
#   ACCOUNT_ID=<id> ACCESS_TOKEN=<token> ./scripts/run-edge-core.sh
#   ./scripts/run-edge-core.sh --account-id <id> --access-token <token>
#
# Environment overrides:
#   EDGE_CORE_IMAGE=<image>   default ghcr.io/izumanetworks/edge-core-dev:0.21.7
#                             use ...edge-core-dev-5684:<tag> for bootstrap over UDP
#   HTTP_PORT=<port>          default 9101
#   RESET_IDENTITY=1          delete the existing device identity and re-provision

set -euo pipefail

EDGE_CORE_IMAGE="${EDGE_CORE_IMAGE:-ghcr.io/izumanetworks/edge-core-dev:0.21.7}"
HTTP_PORT="${HTTP_PORT:-9101}"
CONTAINER_NAME="${CONTAINER_NAME:-edge-core}"
PELION_DIR="/var/lib/pelion/mbed"

ACCOUNT_ID="${ACCOUNT_ID:-}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"

log()  { echo "[edge-core] $*"; }
warn() { echo "[warn] $*" >&2; }
die()  { echo "[error] $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --account-id)   ACCOUNT_ID="${2:-}"; shift 2 ;;
    --access-token) ACCESS_TOKEN="${2:-}"; shift 2 ;;
    --image)        EDGE_CORE_IMAGE="${2:-}"; shift 2 ;;
    --http-port)    HTTP_PORT="${2:-}"; shift 2 ;;
    --reset)        RESET_IDENTITY=1; shift ;;
    --help|-h)      sed -n '3,20p' "$0"; exit 0 ;;
    *)              die "Unknown argument: $1" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "docker not found; run ./scripts/prereqs.sh first"

# Edge Core's entrypoint rejects anything that is not a 32-char hex string or a
# UUID, so catch a bad value here rather than in a container restart loop.
if ! [[ "$ACCOUNT_ID" =~ ^[0-9a-fA-F]{32}$ ]] \
   && ! [[ "$ACCOUNT_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  die "ACCOUNT_ID ('${ACCOUNT_ID}') must be a 32-character hex string or a UUID.
     Find it in the portal under Team Configuration -> Account ID."
fi
[ -n "$ACCESS_TOKEN" ] || die "ACCESS_TOKEN is required.
     Create one in the portal under Access Management -> Access Key -> New Access Key."

# The kubelet needs a Docker daemon that still speaks Engine API v1.38.
if ! docker info >/dev/null 2>&1; then
  die "Cannot reach the Docker daemon. Try: sudo systemctl start docker"
fi

if [ "${RESET_IDENTITY:-0}" = "1" ]; then
  warn "RESET_IDENTITY=1 - deleting the existing device identity in ${PELION_DIR}"
  warn "This device will re-provision and appear as a new device in the portal."
  sudo rm -rf "${PELION_DIR}/mcc_config" "${PELION_DIR}/ec-kcm-conf"
fi

sudo mkdir -p "${PELION_DIR}"
mkdir -p /tmp

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  log "Removing the existing '${CONTAINER_NAME}' container"
  docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

log "Starting ${CONTAINER_NAME} from ${EDGE_CORE_IMAGE}"
# Rotates logs after 50MB, keeping 10 files (~500MB total)
# Communicates using the LwM2M TCP endpoint over 443
docker run --restart unless-stopped \
  -v "${PELION_DIR}/mcc_config:/usr/src/app/mbed-edge/mcc_config" \
  -v "${PELION_DIR}/ec-kcm-conf:/usr/src/app/mbed-edge/edge-gw-config" \
  -v "/tmp:/tmp" \
  -e ACCOUNT_ID="${ACCOUNT_ID}" \
  -e ACCESS_TOKEN="${ACCESS_TOKEN}" \
  -p "${HTTP_PORT}:${HTTP_PORT}" \
  --name "${CONTAINER_NAME}" \
  --log-driver=json-file \
  --log-opt max-size=50m \
  --log-opt max-file=10 \
  -d "${EDGE_CORE_IMAGE}" \
  --cbor-conf /usr/src/app/mbed-edge/edge-gw-config/kcm.cbor \
  --edge-pt-domain-socket /tmp/edge.sock \
  --http-port "${HTTP_PORT}" \
  --bind 0.0.0.0 >/dev/null

log "Waiting for Edge Core to report a status on port ${HTTP_PORT}..."
for _ in $(seq 1 60); do
  if curl -fsS "localhost:${HTTP_PORT}/status" >/dev/null 2>&1; then
    echo ""
    if command -v jq >/dev/null 2>&1; then
      curl -s "localhost:${HTTP_PORT}/status" | jq
    else
      curl -s "localhost:${HTTP_PORT}/status"; echo ""
    fi
    status="$(curl -s "localhost:${HTTP_PORT}/status" | tr -d ' \n')"
    case "$status" in
      *'"status":"connected"'*)
        log "✓ Edge Core is connected."
        exit 0
        ;;
    esac
    warn "Edge Core is up but not yet 'connected'; it may still be registering."
    log  "Follow it with: docker logs -f ${CONTAINER_NAME}"
    exit 0
  fi
  sleep 2
done

warn "Edge Core did not answer on localhost:${HTTP_PORT}/status within 120s."
warn "Provisioning can take a while on first run. Check the logs:"
warn "    docker logs -f ${CONTAINER_NAME}"
exit 1
