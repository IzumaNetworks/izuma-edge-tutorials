#!/usr/bin/env bash

# Collect a support bundle for an Izuma Edge node.
#
# Runs a health check over every thick-edge component, captures host state,
# configuration and logs, and writes a tarball you can send to Izuma support.
# It also prints a short summary suitable for pasting into an email.
#
# Read-only: it inspects the node, it never changes it.
#
# Usage:
#   sudo ./diagnostics/collect-support-bundle.sh [options]
#
# Options:
#   -o, --output-dir <dir>   where to write the tarball (default: /tmp)
#   -j, --journal-lines <n>  journal lines per service (default: 2000)
#   -d, --docker-lines <n>   docker log lines per container (default: 2000)
#   --no-connectivity        skip the reachability tests to Izuma Cloud
#   -h, --help               show this message
#
# Secrets are redacted: access tokens, private keys and kubeconfig credentials
# are never written to the bundle. Device and account identifiers ARE included,
# because support needs them to correlate with the cloud side.

set -uo pipefail

JOURNAL_LINES=2000
DOCKER_LINES=2000
OUTPUT_DIR=/tmp
DO_CONNECTIVITY=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output-dir)   OUTPUT_DIR="${2:?}"; shift 2 ;;
    -j|--journal-lines) JOURNAL_LINES="${2:?}"; shift 2 ;;
    -d|--docker-lines) DOCKER_LINES="${2:?}"; shift 2 ;;
    --no-connectivity) DO_CONNECTIVITY=0; shift ;;
    -h|--help)         sed -n '3,26p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date -u +%Y%m%d-%H%M%SZ)"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo node)"
BUNDLE="izuma-support-${HOSTNAME_SHORT}-${STAMP}"
WORKDIR="$(mktemp -d)"
ROOT="${WORKDIR}/${BUNDLE}"
mkdir -p "$ROOT"

SERVICES="edge-proxy kubelet kube-router kube-router-watcher coredns coredns-starter pe-terminal wait-for-pelion-identity docker containerd"
IZUMA_PACKAGES="pe-utils edge-proxy kubelet pe-terminal containernetworking-plugin-c2d containernetworking-plugins-c2d containernetworking-plugins docker-ce docker-ce-cli containerd.io"
PELION_DIR=/var/lib/pelion

# Health check results, rendered into the summary
CHECKS=()
FAIL_COUNT=0
WARN_COUNT=0

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
say()  { echo "$*"; }
sect() { echo; echo "=== $* ==="; }

# run <relative-output-path> <command...>
# Captures stdout+stderr of a command into the bundle. Never fails the script.
run() {
  local out="$ROOT/$1"; shift
  mkdir -p "$(dirname "$out")"
  {
    echo "\$ $*"
    echo "---"
    "$@" 2>&1
    echo "--- exit=$?"
  } >>"$out" 2>&1 || true
}

# runsh <relative-output-path> <shell snippet>
runsh() {
  local out="$ROOT/$1"; shift
  mkdir -p "$(dirname "$out")"
  {
    echo "\$ $*"
    echo "---"
    bash -c "$*" 2>&1
    echo "--- exit=$?"
  } >>"$out" 2>&1 || true
}

copy() {
  local src="$1" dest="$ROOT/$2"
  [ -e "$src" ] || return 0
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest" 2>/dev/null || true
}

# check <status: ok|warn|fail> <label> <detail>
check() {
  CHECKS+=("$1|$2|$3")
  case "$1" in
    fail) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    warn) WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# Strip anything that looks like a credential.
redact() {
  sed -E \
    -e 's/(ACCESS_TOKEN=)[^[:space:]",]*/\1<REDACTED>/g' \
    -e 's/("access[_-]?token"[[:space:]]*:[[:space:]]*")[^"]*/\1<REDACTED>/gI' \
    -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI' \
    -e 's/("(token|password|secret|apiKey|api_key)"[[:space:]]*:[[:space:]]*")[^"]*/\1<REDACTED>/gI' \
    -e 's/(password=)[^[:space:]&]*/\1<REDACTED>/gI' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/<REDACTED PRIVATE KEY>/g'
}

say "Collecting Izuma Edge support bundle..."
say "  host:   ${HOSTNAME_SHORT}"
say "  bundle: ${BUNDLE}"
[ "$(id -u)" = "0" ] || say "  NOTE: not running as root; some details will be missing. Prefer: sudo $0"

# ---------------------------------------------------------------------------
# 1. host and distribution
# ---------------------------------------------------------------------------
say "  [1/9] host and distribution"
copy /etc/os-release            host/os-release
run  host/uname.txt             uname -a
run  host/uptime.txt            uptime
run  host/date.txt              date -u
run  host/cmdline.txt           cat /proc/cmdline
run  host/lscpu.txt             lscpu
run  host/meminfo.txt           free -h
run  host/disk.txt              df -hT
run  host/mounts.txt            findmnt -A
run  host/limits.txt            ulimit -a

DISTRO_ID="unknown"; DISTRO_VER="unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"; DISTRO_VER="${VERSION_ID:-unknown}"
fi
KERNEL="$(uname -r)"
check ok "OS" "${DISTRO_ID} ${DISTRO_VER}, kernel ${KERNEL}"

# ---------------------------------------------------------------------------
# 2. cgroup hierarchy - Izuma KaaS requires v1
# ---------------------------------------------------------------------------
say "  [2/9] cgroup hierarchy"
run  host/cgroup-fstype.txt     stat -fc %T /sys/fs/cgroup
runsh host/cgroup-mounts.txt    "mount | grep -i cgroup"
copy /proc/cgroups              host/proc-cgroups.txt

CGROUP_FS="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
if [ "$CGROUP_FS" = "cgroup2fs" ]; then
  check fail "cgroup version" "v2 (unified). Izuma KaaS requires v1 - the kubelet will not start. Re-run scripts/prereqs.sh and reboot."
elif [ "$CGROUP_FS" = "tmpfs" ]; then
  check ok "cgroup version" "v1 (legacy hierarchy) - correct for Izuma KaaS"
else
  check warn "cgroup version" "could not determine (stat reported '${CGROUP_FS}')"
fi

# ---------------------------------------------------------------------------
# 3. security policy and firewalling
# ---------------------------------------------------------------------------
say "  [3/9] security policy"
if have getenforce; then
  run host/selinux-getenforce.txt getenforce
  copy /etc/selinux/config        host/selinux-config
  SE_RUN="$(getenforce 2>/dev/null || echo unknown)"
  SE_CFG="$(awk -F= '/^SELINUX=/ {print $2}' /etc/selinux/config 2>/dev/null | tr -d '[:space:]')"
  if [ "$SE_RUN" = "Enforcing" ]; then
    check fail "SELinux" "Enforcing. Izuma Edge ships no SELinux policy; the kubelet and CNI will be denied. Set it permissive."
  elif [ "$SE_CFG" = "enforcing" ]; then
    check fail "SELinux" "running ${SE_RUN} but /etc/selinux/config says enforcing - this host will come back Enforcing after a reboot."
  else
    check ok "SELinux" "${SE_RUN} (on-disk: ${SE_CFG:-n/a})"
  fi
  runsh logs/selinux-denials.txt "journalctl -k --no-pager | grep -i 'avc: *denied' | tail -200"
fi
runsh host/firewalld.txt   "systemctl is-active firewalld; firewall-cmd --list-all 2>/dev/null"
runsh host/nftables.txt    "nft list ruleset 2>/dev/null | head -300"
runsh host/iptables.txt    "iptables --version; iptables-save 2>/dev/null | head -400"
if have iptables; then
  IPT_BACKEND="$(iptables --version 2>/dev/null | grep -o 'nf_tables\|legacy' || echo unknown)"
  check ok "iptables backend" "${IPT_BACKEND}"
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
  check warn "firewalld" "active - it can block CoreDNS on 172.21.2.1:53 and kube-router traffic"
fi

# ---------------------------------------------------------------------------
# 4. packages and dependencies
# ---------------------------------------------------------------------------
say "  [4/9] packages and dependencies"
if have rpm; then
  run packages/all-rpms.txt      rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n'
  runsh packages/izuma.txt       "for p in ${IZUMA_PACKAGES}; do printf '%-40s ' \"\$p\"; rpm -q \"\$p\" 2>&1 | head -1; done"
  run packages/repos.txt         dnf repolist --all
elif have dpkg; then
  run packages/all-debs.txt      dpkg -l
  runsh packages/izuma.txt       "for p in ${IZUMA_PACKAGES}; do printf '%-40s ' \"\$p\"; dpkg-query -W -f='\${Version}\n' \"\$p\" 2>&1 | head -1; done"
  runsh packages/repos.txt       "apt-cache policy; ls /etc/apt/sources.list.d/"
fi
runsh packages/versions-key.txt "for b in docker containerd kubelet edge-proxy pe-terminal coredns kube-router; do printf '%-14s %s\n' \"\$b\" \"\$(command -v \$b || echo not-installed)\"; done"
run packages/glibc.txt          ldd --version

# ---------------------------------------------------------------------------
# 5. docker and edge-core
# ---------------------------------------------------------------------------
say "  [5/9] docker and Edge Core"
if have docker; then
  run docker/version.txt        docker version
  run docker/info.txt           docker info
  run docker/ps.txt             docker ps -a
  run docker/images.txt         docker images
  copy /etc/docker/daemon.json  docker/daemon.json

  DOCKER_CGROUP="$(docker info 2>/dev/null | awk -F': ' '/Cgroup Driver/ {print $2}' | tr -d ' \r')"
  DOCKER_CGVER="$(docker info 2>/dev/null | awk -F': ' '/Cgroup Version/ {print $2}' | tr -d ' \r')"
  DOCKER_MINAPI="$(docker version --format '{{.Server.MinAPIVersion}}' 2>/dev/null)"
  DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"

  if [ -n "$DOCKER_VER" ]; then
    check ok "Docker" "${DOCKER_VER}, cgroup driver ${DOCKER_CGROUP:-?}, cgroup v${DOCKER_CGVER:-?}"
  else
    check fail "Docker" "daemon not responding to 'docker version'"
  fi
  if [ -n "$DOCKER_MINAPI" ]; then
    # kubelet speaks Engine API 1.38
    if [ "$(printf '%s\n%s\n' "$DOCKER_MINAPI" "1.38" | sort -V | head -n1)" = "$DOCKER_MINAPI" ]; then
      check ok "Docker API" "minimum ${DOCKER_MINAPI} (kubelet needs 1.38)"
    else
      check fail "Docker API" "minimum ${DOCKER_MINAPI} > 1.38 - the Izuma kubelet cannot talk to this daemon. Pin Docker to 28.x."
    fi
  fi
  if [ "$DOCKER_CGVER" = "2" ]; then
    check fail "Docker cgroup" "Docker reports cgroup v2; the kubelet requires v1"
  fi

  # Edge Core container. Env is redacted before it lands in the bundle.
  EC="$(docker ps -a --filter 'name=edge-core' --format '{{.Names}}' 2>/dev/null | head -1)"
  if [ -n "$EC" ]; then
    runsh docker/edge-core-inspect.txt "docker inspect '$EC'"
    # redact in place
    if [ -f "$ROOT/docker/edge-core-inspect.txt" ]; then
      redact < "$ROOT/docker/edge-core-inspect.txt" > "$ROOT/docker/edge-core-inspect.txt.tmp" \
        && mv "$ROOT/docker/edge-core-inspect.txt.tmp" "$ROOT/docker/edge-core-inspect.txt"
    fi
    runsh "docker/edge-core-logs.txt" "docker logs --tail ${DOCKER_LINES} --timestamps '$EC'"
    [ -f "$ROOT/docker/edge-core-logs.txt" ] && \
      redact < "$ROOT/docker/edge-core-logs.txt" > "$ROOT/docker/edge-core-logs.txt.tmp" && \
      mv "$ROOT/docker/edge-core-logs.txt.tmp" "$ROOT/docker/edge-core-logs.txt"

    EC_RUNNING="$(docker inspect "$EC" --format '{{.State.Running}}' 2>/dev/null)"
    EC_POLICY="$(docker inspect "$EC" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)"
    if [ "$EC_RUNNING" = "true" ]; then
      check ok "Edge Core container" "running (restart policy: ${EC_POLICY})"
    else
      check fail "Edge Core container" "not running (restart policy: ${EC_POLICY}). Start it with scripts/run-edge-core.sh"
    fi
    if [ "$EC_POLICY" = "unless-stopped" ]; then
      check warn "Edge Core restart policy" "'unless-stopped' does not survive a host reboot; use --restart always"
    fi
  else
    check fail "Edge Core container" "no container named edge-core found"
  fi

  # Edge Core status endpoint
  EC_STATUS="$(curl -fsS --max-time 10 http://localhost:9101/status 2>/dev/null)"
  if [ -n "$EC_STATUS" ]; then
    mkdir -p "$ROOT/edge"
    echo "$EC_STATUS" | redact > "$ROOT/edge/status.json"
    ST="$(echo "$EC_STATUS" | tr -d ' \n' | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    ACCOUNT_ID_SEEN="$(echo "$EC_STATUS" | tr -d ' \n' | sed -n 's/.*"account-id":"\([^"]*\)".*/\1/p')"
    DEVICE_ID_SEEN="$(echo "$EC_STATUS" | tr -d ' \n' | sed -n 's/.*"internal-id":"\([^"]*\)".*/\1/p')"
    if [ "$ST" = "connected" ]; then
      check ok "Edge Core status" "connected to Izuma Cloud"
    else
      check fail "Edge Core status" "status is '${ST:-unknown}', expected 'connected'"
    fi
  else
    check fail "Edge Core status" "http://localhost:9101/status not answering"
  fi
else
  check fail "Docker" "docker command not found - run scripts/prereqs.sh"
fi

# Protocol translator socket: non-root translators need write permission
if [ -S /tmp/edge.sock ]; then
  SOCK_MODE="$(stat -c '%a' /tmp/edge.sock 2>/dev/null)"
  run edge/edge-sock.txt ls -la /tmp/edge.sock
  case "$SOCK_MODE" in
    *[2367])  check ok   "PT socket /tmp/edge.sock" "mode ${SOCK_MODE} - writable by others, translators can connect" ;;
    *)        check warn "PT socket /tmp/edge.sock" "mode ${SOCK_MODE} - not writable by others; non-root protocol translators will fail with 'Permission denied'" ;;
  esac
else
  check warn "PT socket /tmp/edge.sock" "not present (Edge Core may not be running)"
fi

# ---------------------------------------------------------------------------
# 6. systemd services
# ---------------------------------------------------------------------------
say "  [6/9] systemd services"
run systemd/list-units.txt       systemctl list-units --all --no-pager
run systemd/list-unit-files.txt  systemctl list-unit-files --no-pager
run systemd/failed.txt           systemctl --failed --no-pager
run systemd/list-jobs.txt        systemctl list-jobs --no-pager
run systemd/default-target.txt   systemctl get-default
runsh systemd/network-target-wants.txt "ls -la /etc/systemd/system/network.target.wants/ 2>&1"
runsh systemd/multi-user-wants.txt     "ls -la /etc/systemd/system/multi-user.target.wants/ 2>&1"
runsh systemd/ordering-cycles.txt      "journalctl -b --no-pager | grep -i 'ordering cycle' | head -40"

for svc in $SERVICES; do
  runsh "systemd/units/${svc}.txt" "systemctl cat ${svc} 2>&1; echo; systemctl status ${svc} --no-pager 2>&1"
done

# Distinguish a boot that is still stuck from one that merely lost the
# multi-user.target job. Pending jobs mean something is genuinely blocking;
# an inactive target with a drained queue usually means systemd dropped that
# job earlier to break an ordering cycle, and everything else did start.
PENDING_JOBS="$(systemctl list-jobs --no-legend --no-pager 2>/dev/null | grep -cvi 'no jobs')"
PENDING_JOBS="${PENDING_JOBS//[^0-9]/}"; PENDING_JOBS="${PENDING_JOBS:-0}"
if [ "${PENDING_JOBS:-0}" -gt 0 ]; then
  BLOCKING="$(systemctl list-jobs --no-legend --no-pager 2>/dev/null | awk '$3=="running"{print $2}' | tr '\n' ' ')"
  check fail "Boot completion" "${PENDING_JOBS} systemd job(s) still pending - the boot has not finished. Waiting on: ${BLOCKING:-see systemd/list-jobs.txt}"
elif ! systemctl is-active --quiet multi-user.target 2>/dev/null; then
  check warn "Boot completion" "multi-user.target is inactive but no jobs are pending; its job was probably dropped to break an ordering cycle. Services started, but check systemd/ordering-cycles.txt"
else
  check ok "Boot completion" "multi-user.target reached"
fi

# grep -c prints 0 and exits 1 when there are no matches; a `|| echo 0` here
# would append a second line and produce "0\n0", which is not an integer.
CYCLES="$(journalctl -b --no-pager 2>/dev/null | grep -ci 'ordering cycle')"
CYCLES="${CYCLES//[^0-9]/}"; CYCLES="${CYCLES:-0}"
if [ "${CYCLES:-0}" -gt 0 ]; then
  check fail "systemd ordering" "${CYCLES} ordering-cycle messages this boot - systemd deleted a job to break a loop, which usually stops containerd or docker. See systemd/ordering-cycles.txt"
else
  check ok "systemd ordering" "no ordering cycles this boot"
fi

if [ -e /etc/systemd/system/network.target.wants/kube-router.service ]; then
  check fail "kube-router target" "kube-router is wanted by network.target, which creates a boot dependency cycle with containerd. Re-run scripts/install-thick-edge-services.sh"
fi

FAILED_UNITS="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
[ -n "${FAILED_UNITS// /}" ] && check warn "Failed units" "${FAILED_UNITS}"

for svc in edge-proxy kubelet kube-router coredns pe-terminal wait-for-pelion-identity; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 && \
     systemctl cat "${svc}.service" >/dev/null 2>&1; then
    STATE="$(systemctl is-active "$svc" 2>/dev/null)"
    if [ "$STATE" = "active" ]; then
      check ok "service ${svc}" "active"
    else
      check fail "service ${svc}" "${STATE}"
    fi
  else
    check fail "service ${svc}" "unit file not installed"
  fi
done

# ---------------------------------------------------------------------------
# 6b. KaaS API entitlement
#
# The kubelet carries no credentials of its own: its kubeconfig points at
# edge-proxy on 127.0.0.1:8080 over plain HTTP, and edge-proxy attaches the
# device certificate when it forwards to edge-k8s. Probing through edge-proxy
# therefore exercises exactly the path the kubelet uses, and the status code
# separates causes that otherwise all present as "the node never appears in
# kubectl get nodes".
#
# A device can be fully healthy - registered over LwM2M, reverse tunnel up -
# and still be refused here, because container orchestration is a per-account
# feature. That case is a 401, and it is not something the customer can fix on
# the node.
# ---------------------------------------------------------------------------
say "  [6b/9] KaaS API entitlement"
ACCOUNT_ID_SEEN="${ACCOUNT_ID_SEEN:-}"
DEVICE_ID_SEEN="${DEVICE_ID_SEEN:-}"
if [ -z "$ACCOUNT_ID_SEEN" ] && [ -r "${PELION_DIR}/edge_gw_config/identity.json" ]; then
  ACCOUNT_ID_SEEN="$(sed -n 's/.*"OU"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${PELION_DIR}/edge_gw_config/identity.json" | head -1)"
fi
ACCOUNT_TXT="${ACCOUNT_ID_SEEN:-<unknown>}"

runsh kaas/api-probe.txt "curl -s -o /dev/null -w 'nodes:%{http_code}\n' --max-time 20 'http://127.0.0.1:8080/api/v1/nodes?limit=1'; curl -s --max-time 20 'http://127.0.0.1:8080/api/v1/nodes?limit=1' | head -c 600"
runsh kaas/kubelet-registration.txt "journalctl -u kubelet -n 4000 --no-pager | grep -iE 'register node|not found|provide credentials' | tail -40"

# How many times has the kubelet been refused, and did it ever succeed?
REG_FAIL="$(journalctl -u kubelet -n 4000 --no-pager 2>/dev/null | grep -c 'Unable to register node')"
REG_FAIL="${REG_FAIL//[^0-9]/}"; REG_FAIL="${REG_FAIL:-0}"
REG_OK="$(journalctl -u kubelet -n 4000 --no-pager 2>/dev/null | grep -c 'Successfully registered node')"
REG_OK="${REG_OK//[^0-9]/}"; REG_OK="${REG_OK:-0}"

if systemctl is-active --quiet edge-proxy 2>/dev/null; then
  KAAS_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 'http://127.0.0.1:8080/api/v1/nodes?limit=1' 2>/dev/null)"
else
  KAAS_CODE="skip"
fi

case "$KAAS_CODE" in
  200)
    check ok "KaaS API (edge-k8s)" "HTTP 200 - the device is authorised for container orchestration"
    ;;
  401)
    check fail "KaaS API (edge-k8s)" "HTTP 401. Container orchestration (edge-k8s) is not enabled for account ${ACCOUNT_TXT}. The device itself is fine - it is registered over LwM2M and its certificate is accepted by the gateway service; only edge-k8s refuses it. This is an account entitlement, so it cannot be fixed on this node: ask Izuma to enable the edge-k8s feature flag for this account."
    ;;
  403)
    check fail "KaaS API (edge-k8s)" "HTTP 403. The device authenticated but is not permitted to use container orchestration on account ${ACCOUNT_TXT}. Ask Izuma to check this account's edge-k8s entitlement and this device's permissions."
    ;;
  000)
    check warn "KaaS API (edge-k8s)" "edge-proxy did not answer on 127.0.0.1:8080; cannot tell whether edge-k8s accepts this device"
    ;;
  skip)
    check warn "KaaS API (edge-k8s)" "edge-proxy is not active, so the KaaS path could not be tested"
    ;;
  *)
    check warn "KaaS API (edge-k8s)" "unexpected HTTP ${KAAS_CODE} from edge-k8s via edge-proxy"
    ;;
esac

if [ "$REG_FAIL" -gt 0 ] && [ "$REG_OK" -eq 0 ]; then
  check fail "Node registration" "the kubelet has been refused ${REG_FAIL} time(s) and has never registered, so this node will not appear in 'kubectl get nodes'. See the KaaS API check above for the reason."
elif [ "$REG_OK" -gt 0 ]; then
  check ok "Node registration" "the kubelet registered node ${DEVICE_ID_SEEN:-this device} with the API server"
fi

# ---------------------------------------------------------------------------
# 7. networking and CNI
# ---------------------------------------------------------------------------
say "  [7/9] networking and CNI"
run  net/ip-addr.txt        ip -d addr
run  net/ip-route.txt       ip route
run  net/ip-link.txt        ip -br link
run  net/sockets.txt        ss -lntup
run  net/resolv.conf.txt    cat /etc/resolv.conf
copy /etc/hosts             net/hosts
runsh net/bridges.txt       "ip -d link show type bridge 2>&1; bridge link 2>/dev/null"
runsh net/sysctl.txt        "sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables 2>&1"
runsh net/modules.txt       "lsmod | grep -E 'br_netfilter|overlay|ip_vs|nf_conntrack' 2>&1"
copy /etc/cni/net.d         cni/net.d
runsh cni/plugin-dirs.txt   "for d in /usr/lib/cni /usr/libexec/cni /opt/cni/bin; do echo \"--- \$d\"; ls -la \"\$d\" 2>&1 | head -30; done"
copy /etc/NetworkManager/conf.d net/NetworkManager-conf.d

# CNI plugin directory: the kubelet is launched with --cni-bin-dir=/usr/lib/cni
CNI_OK=0
for p in bridge host-local portmap; do
  [ -x "/usr/lib/cni/$p" ] || CNI_OK=1
done
if [ "$CNI_OK" = "0" ]; then
  check ok "CNI plugins" "/usr/lib/cni has bridge, host-local and portmap"
else
  if [ -d /usr/libexec/cni ]; then
    check fail "CNI plugins" "/usr/lib/cni is missing plugins but /usr/libexec/cni exists - the kubelet looks in /usr/lib/cni, so pods will hang in ContainerCreating. Re-run scripts/install-thick-edge-services.sh"
  else
    check fail "CNI plugins" "no CNI plugins found in /usr/lib/cni - pods will hang in ContainerCreating"
  fi
fi

# kube-bridge carries 172.21.2.1, which CoreDNS binds
if ip link show kube-bridge >/dev/null 2>&1; then
  if ip -4 addr show kube-bridge 2>/dev/null | grep -q '172\.21\.2\.1/24'; then
    check ok "kube-bridge" "present with 172.21.2.1/24"
  else
    check warn "kube-bridge" "present but without 172.21.2.1/24 - CoreDNS cannot bind"
  fi
else
  check warn "kube-bridge" "not present. kube-router creates it when the first pod is scheduled; CoreDNS stays down until then (coredns-starter will start it automatically)"
fi

# ---------------------------------------------------------------------------
# 8. Izuma configuration and identity
# ---------------------------------------------------------------------------
say "  [8/9] Izuma configuration"
runsh edge/pelion-tree.txt "ls -laR ${PELION_DIR} 2>&1 | head -200"
if [ -f "${PELION_DIR}/edge_gw_config/identity.json" ]; then
  redact < "${PELION_DIR}/edge_gw_config/identity.json" > "$ROOT/edge/identity.json" 2>/dev/null
  check ok "identity.json" "present"
else
  check fail "identity.json" "missing - Edge Core has not registered, so edge-proxy cannot start"
fi
copy /etc/pelion            edge/etc-pelion
# never ship key material
find "$ROOT/edge" -type f \( -name '*.key' -o -name '*key.pem' -o -name '*PrivateKey*' -o -name '*.cbor' \) -delete 2>/dev/null || true
runsh edge/kubelet-cmdline.txt "ps -ef | grep -E '[k]ubelet|[e]dge-proxy|[k]ube-router|[c]oredns' 2>&1"

# ---------------------------------------------------------------------------
# 9. logs and connectivity
# ---------------------------------------------------------------------------
say "  [9/9] logs and connectivity"
for svc in $SERVICES; do
  runsh "logs/${svc}.log" "journalctl -u ${svc} -n ${JOURNAL_LINES} --no-pager"
  if [ -f "$ROOT/logs/${svc}.log" ]; then
    redact < "$ROOT/logs/${svc}.log" > "$ROOT/logs/${svc}.log.tmp" && mv "$ROOT/logs/${svc}.log.tmp" "$ROOT/logs/${svc}.log"
  fi
done
runsh logs/dmesg.txt          "dmesg -T | tail -500"
runsh logs/journal-boot.txt   "journalctl -b -p warning -n 1000 --no-pager"
runsh logs/journal-list.txt   "journalctl --list-boots --no-pager | tail -20"

if [ "$DO_CONNECTIVITY" = "1" ]; then
  for host_port in \
    "tcp-bootstrap.us-east-1.mbedcloud.com 443" \
    "tcp-lwm2m.us-east-1.mbedcloud.com 443" \
    "gateways.us-east-1.mbedcloud.com 443" \
    "edge-k8s.us-east-1.mbedcloud.com 443"; do
    set -- $host_port
    # The result marker is anchored to the start of a line. runsh echoes the
    # command itself into the file, so a substring match would also hit the
    # literal text of the `|| echo` branch and report every host as failed.
    runsh "connectivity/$1.txt" "getent hosts $1; timeout 10 bash -c '</dev/tcp/$1/$2' && echo 'RESULT=reachable' || echo 'RESULT=unreachable'"
  done
  REACH_FAIL=0
  for f in "$ROOT"/connectivity/*.txt; do
    [ -f "$f" ] || continue
    grep -q '^RESULT=reachable' "$f" || REACH_FAIL=$((REACH_FAIL + 1))
  done
  if [ "$REACH_FAIL" = "0" ]; then
    check ok "Cloud reachability" "all Izuma endpoints reachable on 443"
  else
    check fail "Cloud reachability" "${REACH_FAIL} Izuma endpoint(s) unreachable on 443 - check egress firewall. See connectivity/"
  fi
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
SUMMARY="$ROOT/SUMMARY.txt"
{
  echo "Izuma Edge support bundle"
  echo "========================="
  echo "Host          : ${HOSTNAME_SHORT}"
  echo "Collected     : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "OS / kernel   : ${DISTRO_ID} ${DISTRO_VER} / ${KERNEL}"
  echo "Bundle        : ${BUNDLE}.tar.gz"
  echo
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "RESULT: ${FAIL_COUNT} problem(s), ${WARN_COUNT} warning(s)"
  elif [ "$WARN_COUNT" -gt 0 ]; then
    echo "RESULT: no problems, ${WARN_COUNT} warning(s)"
  else
    echo "RESULT: all checks passed"
  fi
  echo
  echo "Checks"
  echo "------"
  for entry in "${CHECKS[@]}"; do
    st="${entry%%|*}"; rest="${entry#*|}"
    label="${rest%%|*}"; detail="${rest#*|}"
    case "$st" in
      ok)   mark="[ OK ]" ;;
      warn) mark="[WARN]" ;;
      fail) mark="[FAIL]" ;;
    esac
    printf '%s %-28s %s\n' "$mark" "$label" "$detail"
  done
  echo
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "Problems to look at first"
    echo "-------------------------"
    for entry in "${CHECKS[@]}"; do
      case "$entry" in
        fail\|*) rest="${entry#*|}"; printf '  - %s: %s\n' "${rest%%|*}" "${rest#*|}" ;;
      esac
    done
    echo
  fi
  echo "Contents"
  echo "--------"
  echo "  host/          OS, kernel, cgroups, CPU, memory, disk"
  echo "  packages/      installed packages and Izuma component versions"
  echo "  docker/        Docker version/info, containers, Edge Core inspect and logs"
  echo "  systemd/       unit files, drop-ins, status, pending jobs, ordering cycles"
  echo "  net/ cni/      interfaces, routes, sockets, sysctls, CNI config and plugins"
  echo "  edge/          Izuma configuration and identity"
  echo "  logs/          per-service journals, dmesg, boot warnings"
  echo "  kaas/          edge-k8s API probe and kubelet registration history"
  echo "  connectivity/  reachability of the Izuma Cloud endpoints"
  echo
  echo "Access tokens, private keys and passwords are redacted."
} > "$SUMMARY"

# ---------------------------------------------------------------------------
# package it up
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
TARBALL="${OUTPUT_DIR}/${BUNDLE}.tar.gz"
tar -czf "$TARBALL" -C "$WORKDIR" "$BUNDLE" 2>/dev/null
chmod 0600 "$TARBALL" 2>/dev/null || true
rm -rf "$WORKDIR"

echo
tar -xzOf "$TARBALL" "${BUNDLE}/SUMMARY.txt" 2>/dev/null
echo
echo "==============================================================="
echo "Bundle written to: ${TARBALL}"
echo "Size: $(du -h "$TARBALL" 2>/dev/null | cut -f1)"
echo
echo "Please attach that file to your email to Izuma support, and paste"
echo "the summary above into the message body."
echo "==============================================================="

[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
