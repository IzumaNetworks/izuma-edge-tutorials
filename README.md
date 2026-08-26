## Getting started with Izuma Edge on Ubuntu 22.04/24.04 and AlmaLinux 9

This guide walks you through running and managing your Edge application in a container using Izuma's KaaS (Kubernetes‑as‑a‑Service). Edge Core (mbed-edge) runs in a Docker container, while components such as edge-proxy, kubelet, and pe-utils run natively on the host as distribution packages.

The scripts in `scripts/` detect the host distribution and use the right package manager:

| Host | Packages | Package manager |
| --- | --- | --- |
| Ubuntu 20.04 / 22.04 / 24.04 | `.deb` | `apt` |
| AlmaLinux 9, Rocky Linux 9, RHEL 9, CentOS Stream 9 | `.rpm` | `dnf` |

> **Note:** RPM builds of the thick-edge components (`pe-utils`, `edge-proxy`, `kubelet`, `containernetworking-plugins-c2d`, `pe-terminal`) are **not published yet**. On RHEL 9 derivatives, the prerequisites and Edge Core steps work today; see [Installing on RHEL 9 derivatives](#installing-on-rhel-9-derivatives) for how to point the installer at your own RPM repository.


### Requirements

- Ubuntu 22.04/24.04, **or** AlmaLinux 9 / Rocky Linux 9 / RHEL 9 (tested on 2 CPU, 2 GB RAM, 16 GB disk).

Identify the host with:

```sh
cat /etc/os-release
```

The Ubuntu reference machine these steps were originally validated against - 

```sh
lsb_release -a
```
> **Results:**
> ```sh
> No LSB modules are available.
> Distributor ID: Ubuntu
> Description:    Ubuntu 24.04.3 LTS
> Release:        24.04
> Codename:       noble
> ```
 - Tested on VM with 2 CPU, 2GB Memory and 16GB Disk
```sh
uname -a && lsb_release -a && echo && uptime && echo && free -h && echo && df -hT /
```
> **Results:**
> ```sh
> Linux edge-core-simple-ubuntu-24-2c2m16d 6.8.0-71-generic #71-Ubuntu SMP PREEMPT_DYNAMIC Tue Jul 22 16:52:38 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
> No LSB modules are available.
> Distributor ID: Ubuntu
> Description:    Ubuntu 24.04.3 LTS
> Release:        24.04
> Codename:       noble
>  08:22:50 up 7 min,  1 user,  load average: 0.21, 0.26, 0.13
>                total        used        free      shared  buff/cache   available
> Mem:           1.7Gi       567Mi        89Mi        40Mi       1.3Gi       1.2Gi
> Swap:             0B          0B          0B
> Filesystem     Type  Size  Used Avail Use% Mounted on
> /dev/sda2      ext4   15G  2.9G   12G  20% /
> 
> $ lscpu | grep -E '^Model name|^CPU\(s\):|^Architecture' && echo && nproc
> Architecture:                         x86_64
> CPU(s):                               2
> Model name:                           Intel(R) Xeon(R) CPU E5-2683 v4 @ 2.10GHz
> 2
> ```
- Login access to `https://portal.mbedcloud.com`

### Prerequisites: Install Docker and enable cgroup v1

Run the following script on your host. It will:
- Install Docker (pinned to 28.x) and common utilities
- Configure cgroup v1 (required by the Izuma Edge kubelet)
- Report anything about the host's security policy that would block Izuma Edge
- Prompt for reboot when done

```sh
./scripts/prereqs.sh
```

Environment overrides:

| Variable | Effect |
| --- | --- |
| `DOCKER_MAJOR_PIN=27` | Install a different Docker major (must be `28` or lower) |
| `REBOOT_MODE=yes\|no\|ask` | What to do once the cgroup change is staged. Defaults to `ask`, and to `no` when stdin is not a terminal (for example over `ssh host './scripts/prereqs.sh'`) |
| `SELINUX_SET_PERMISSIVE=0` | Keep the host's current SELinux setting. The **default is to set SELinux permissive**, and the script says so before the reboot |

After reboot, verify:
```sh
stat -fc %T /sys/fs/cgroup | grep -q cgroup2 && echo "cgroup v2" || echo "cgroup v1"
```

You should see `cgroup v1`. Confirm Docker picked it up too - the `Cgroup Driver` must be
`cgroupfs` and `Cgroup Version` must be `1`, which is what the KaaS kubelet expects:

```sh
docker info | grep -i cgroup
```

### Credentials
Login to `https://portal.mbedcloud.com` and obtain the following credentials:
- Access Token: Used by Edge Core to create developer certificate.
  1. Access Management → Applications → New Application (top right)
  2. Access Management → Access Key → New Access Key (top right)
- Account ID: Your organization's account id with Izuma Networks
  1. Team Configuration → Account ID

### Run Izuma Edge

#### 1) Run Edge Core (container)

Edge Core ships as a container image, so this step is identical on Ubuntu and on
AlmaLinux 9. Either use the helper script:

```sh
ACCOUNT_ID=<your_account_id> ACCESS_TOKEN=<your_access_key> ./scripts/run-edge-core.sh
```

It validates the credentials up front, starts the container, and waits for
`/status` to report `connected`. Pass `--reset` to discard the existing device
identity and re-provision as a new device.

Or run the equivalent command by hand - replace the placeholders and run:
```sh
## When re-provisioning as a new device, clean up old credentials
# sudo rm -rf /var/lib/pelion/mbed/mcc_config
# sudo rm -rf /var/lib/pelion/mbed/ec-kcm-conf

sudo mkdir -p /var/lib/pelion/mbed
mkdir -p /tmp

ACCOUNT_ID="replace_with_account_id"
ACCESS_TOKEN="replace_with_access_key"

# Rotates logs after 50MB, keeping 10 files (~500MB total)
# Communicate using LwM2M TCP endpoint over 443
docker run --restart unless-stopped \
  -v "/var/lib/pelion/mbed/mcc_config:/usr/src/app/mbed-edge/mcc_config" \
  -v "/var/lib/pelion/mbed/ec-kcm-conf:/usr/src/app/mbed-edge/edge-gw-config" \
  -v "/tmp:/tmp" \
  -e ACCOUNT_ID="${ACCOUNT_ID}" \
  -e ACCESS_TOKEN="${ACCESS_TOKEN}" \
  -p 9101:9101 \
  --name edge-core \
  --log-driver=json-file \
  --log-opt max-size=50m \
  --log-opt max-file=10 \
  -d ghcr.io/izumanetworks/edge-core-dev:0.21.7 \
  --cbor-conf /usr/src/app/mbed-edge/edge-gw-config/kcm.cbor \
  --edge-pt-domain-socket /tmp/edge.sock \
  --http-port 9101 \
  --bind 0.0.0.0
```

Verify connection:
```sh
curl -s localhost:9101/status | jq
```
Expected success fields include:
```json
{
  "status": "connected",
  "account-id": "...",
  "endpoint-name": "...",
  "internal-id": "...",
  "lwm2m-server-uri": "coaps://tcp-lwm2m.us-east-1.mbedcloud.com:443?aid=..."
}
```

View Edge Core logs:
```sh
docker logs edge-core
```

To communicate using Bootstrap UDP endpoint over 5684

```sh
docker stop edge-core
docker rm edge-core
sudo rm -rf /var/lib/pelion/mbed/mcc_config
sudo rm -rf /var/lib/pelion/mbed/ec-kcm-conf
docker run --rm \
  -v "/var/lib/pelion/mbed/mcc_config:/usr/src/app/mbed-edge/mcc_config" \
  -v "/var/lib/pelion/mbed/ec-kcm-conf:/usr/src/app/mbed-edge/edge-gw-config" \
  -v "/tmp:/tmp" \
  -e ACCOUNT_ID="${ACCOUNT_ID}" \
  -e ACCESS_TOKEN="${ACCESS_TOKEN}" \
  -p 9101:9101 \
  --name edge-core \
  --log-driver=json-file \
  --log-opt max-size=50m \
  --log-opt max-file=10 \
  -d ghcr.io/izumanetworks/edge-core-dev-5684:0.21.6 \
  --cbor-conf /usr/src/app/mbed-edge/edge-gw-config/kcm.cbor \
  --edge-pt-domain-socket /tmp/edge.sock \
  --http-port 9101 \
  --bind 0.0.0.0
```


#### 2) Install thick edge services

Run the following script to install services required for Izuma's container orchestration solution: edge-proxy, kubelet, pe-utils, kube-router, coredns, and pe-terminal.

```sh
./scripts/install-thick-edge-services.sh
```

It installs the native packages for the detected distribution (`.deb` on Ubuntu, `.rpm` on
RHEL 9 derivatives), then the distribution-independent `kubelet`, `kube-router` and
`coredns` tarballs, and prepares host networking (`br_netfilter`/`overlay` modules,
forwarding sysctls, and on RHEL a NetworkManager rule so it leaves the CNI interfaces alone).

Environment overrides:

| Variable | Effect |
| --- | --- |
| `IZUMA_PKG_BASE_URL=<url>` | Fetch the native packages from your own repository |
| `IZUMA_TARBALL_BASE_URL=<url>` | Fetch the service tarballs from somewhere else |
| `SKIP_PACKAGE_INSTALL=1` | Skip the native package stage and install only the tarball services |

The script checks that every package it needs actually exists before changing anything, so a
distribution without published packages stops with a clear message instead of a half-installed host.

This script also installs **pe-terminal**, which provides a remote debug terminal accessible from the Izuma Device Management Portal. pe-terminal requires edge-proxy to be running, so it is installed last after all other services are validated.

To check status of the services, pe-utils provides a status utility:
```sh
sudo edge-info -m
```
Note: Services maestro, fluentbit, devicedb, and relay-term are expected to be inactive. They are not essential for container orchestration. You can install and enable them later based on your use case.

Check service status:
```sh
systemctl --no-pager status edge-proxy
systemctl --no-pager status kubelet
systemctl --no-pager status kube-router
systemctl --no-pager status coredns
systemctl --no-pager status pe-terminal
```

View logs:
```sh
sudo journalctl -u kubelet -n 200 --no-pager 
sudo journalctl -u edge-proxy -n 200 --no-pager
sudo journalctl -u coredns -n 200 --no-pager
sudo journalctl -u kube-router -n 200 --no-pager
sudo journalctl -u pe-terminal -n 200 --no-pager
```

### Installing on RHEL 9 derivatives

Validated on AlmaLinux 9.8 (kernel 5.14.0-687.39.1.el9_8.x86_64). Rocky Linux 9, RHEL 9 and
CentOS Stream 9 use the same package set and should behave identically.

The scripts handle the differences below automatically; they are documented here because they
are the things that break a hand-rolled install.

**cgroup v1.** RHEL 9 boots the unified (v2) hierarchy, and it has no `update-grub`. `prereqs.sh`
uses `grubby --update-kernel=ALL` to add `systemd.unified_cgroup_hierarchy=0` and
`systemd.legacy_systemd_cgroup_controller` to every BLS boot entry, and also records them in
`/etc/default/grub` so a regenerated config keeps them. The v1 controllers are deprecated on
RHEL 9 but still compiled in, so this works; the script verifies `/proc/cgroups` before staging
the change. After the reboot, Docker switches to `Cgroup Driver: cgroupfs` / `Cgroup Version: 1`,
which is what the KaaS kubelet needs.

**SELinux, and why permissive is the default.** Installing Docker pulls in
`container-selinux` and `selinux-policy-targeted`. On a host that booted with
SELinux disabled, that makes the **next boot Enforcing**, even though
`getenforce` still reads `Disabled` or `Permissive` beforehand.

Izuma Edge ships no SELinux policy, so an enforcing host denies the kubelet and
the kube-router CNI. Worse, it can lock you out: on an Incus/LXD virtual machine
the guest agent is denied its vsock socket, so the hypervisor reports no IP and
`incus shell` fails while the VM runs normally and SSH never comes up.

```
avc: denied { create } for comm="incus-agent" ... tclass=vsock_socket permissive=0
```

`prereqs.sh` therefore sets SELinux permissive **by default**, in both the
running mode and `/etc/selinux/config`, and prints a prominent notice before the
reboot. `SELINUX_SET_PERMISSIVE=0` keeps your current setting and warns about
what it costs.

**firewalld.** Not active on a minimal image, but if you enable it, its default zone drops CoreDNS
(`172.21.2.1:53`) and kube-router traffic. Trust the bridge interfaces:

```sh
sudo firewall-cmd --permanent --zone=trusted --add-interface=kube-bridge
sudo firewall-cmd --permanent --zone=trusted --add-interface=docker0
sudo firewall-cmd --reload
```

**NetworkManager.** Runs by default on RHEL 9 and is absent from Ubuntu Server. It claims the
bridge and veth interfaces kube-router creates and tears their addressing down.
`install-thick-edge-services.sh` writes
`/etc/NetworkManager/conf.d/99-izuma-edge-unmanaged.conf` to keep it away from `kube-bridge`,
`kube-dummy-if`, `cni0`, `docker0`, `veth*` and `tun-*`.

**Kernel modules and sysctls.** Ubuntu's Docker packaging loads `br_netfilter` and enables
forwarding as a side effect; a minimal RHEL 9 image does neither, and without them kube-router's
iptables rules never see bridged traffic. The installer writes
`/etc/modules-load.d/izuma-edge.conf` and `/etc/sysctl.d/99-izuma-edge.conf`.

**CNI plugin directory.** The kubelet launcher shipped in `kubelet.tar.gz` hardcodes
`--cni-bin-dir=/usr/lib/cni`, which is where Debian's `containernetworking-plugins`
package installs the CNI binaries. RHEL 9 packages them under `/usr/libexec/cni`
instead. With no plugin where kubelet looks, every pod sandbox fails to get a
network and the `pause` container is torn down immediately, so pods sit in
`ContainerCreating` indefinitely - and the kubelet log says nothing obvious.
`install-thick-edge-services.sh` links `/usr/lib/cni` to `/usr/libexec/cni`. To
check by hand:

```sh
ls -l /usr/lib/cni            # should exist, with bridge/host-local/portmap in it
docker ps -a --filter name=k8s_POD    # pause containers Exited = CNI is failing
```

**iptables backend.** RHEL 9 defaults to the `nf_tables` backend. kube-router 1.2.0 shells out to
the `iptables` binary, and rules written through one backend are invisible to the other. The
installer reports the active backend. If pod networking or CoreDNS misbehaves, check where the
rules landed:

```sh
sudo iptables-save | grep -i kube
sudo nft list ruleset | grep -i kube
```

**Missing base utilities.** A minimal RHEL 9 cloud image ships without `tar`, `wget`, `bc`,
`jq`, `ipset`, `net-tools`, `bind-utils` and `nmap-ncat`. `prereqs.sh` installs them; everything
needed comes from the AlmaLinux BaseOS/AppStream repositories, so **EPEL is not required**.

#### Building and serving the RPMs

The thick-edge components are not published as RPMs yet. `install-thick-edge-services.sh` expects
these filenames under `IZUMA_PKG_BASE_URL`:

```
pe-utils-2.0.7-1.el9.x86_64.rpm
edge-proxy-1.0.0-1.el9.x86_64.rpm
containernetworking-plugin-c2d-0.8.4-1.el9.x86_64.rpm
kubelet-1.0.0-1.el9.x86_64.rpm
pe-terminal-1.0.0-1.el9.x86_64.rpm
```

Two things differ from the Debian side, and the installer accounts for both:

* The CNI plugin is `containernetworking-plugins-c2d` as a `.deb` but
  `containernetworking-plugin-c2d` (**singular**) as an `.rpm`.
* The RPM specs in [distro-pelion-edge](https://github.com/PelionIoT/distro-pelion-edge)
  lag the Debian packaging, so the versions are lower. Build them with the
  `almalinux/9` target, which produces exactly these `.el9` files:

  ```sh
  ./build-env/bin/build-all.sh --docker=almalinux/9 --arch=amd64 --install --container
  ```

Once they are built, point the installer at them:

```sh
IZUMA_PKG_BASE_URL=https://my-host/rpms ./scripts/install-thick-edge-services.sh
```

The `kubelet`, `kube-router` and `coredns` tarballs are **not** distribution specific - they are
static binaries plus systemd units copied into `/usr/bin`, `/etc/systemd/system` and
`/etc/cni/net.d` - so they install unchanged on RHEL 9. To bring up only those while the RPMs are
still being built:

```sh
SKIP_PACKAGE_INSTALL=1 ./scripts/install-thick-edge-services.sh
```

Note that edge-proxy, kubelet and pe-utils will be missing in that mode, so the services will not
be fully functional; it is useful for validating the tarball and networking steps only.

### Download integrity

Every artifact the install scripts fetch - the native packages and the
`kubelet`, `kube-router` and `coredns` tarballs - is downloaded over **HTTPS**
and checked against a pinned SHA-256 in [`scripts/checksums.sha256`](scripts/checksums.sha256)
before anything is installed.

The tarballs matter most: each is extracted and its `install.sh` is run with
`sudo`, so a swapped tarball is arbitrary code as root. They are verified before
extraction.

`scripts/checksums.sha256` is the trust anchor. It reaches the host with the
scripts, over git/HTTPS, rather than alongside the packages - so a tampered
artifact is rejected even if the transport or the object store is compromised.

Verification fails closed: an artifact whose hash does not match, or that has no
pinned hash at all, is refused rather than installed.

```
[warn] CHECKSUM MISMATCH for edge-proxy-1.0.0-1.el9.x86_64.rpm
[warn]   expected 0000000000000000000000000000000000000000000000000000000000000000
[warn]   actual   edc81796af18cc38344e8e1c0bec2e41977e32a557b9e1ac76c1dbc6c2700020
[error] Refusing to install edge-proxy-1.0.0-1.el9.x86_64.rpm: checksum verification failed
```

If you publish your own packages, add their hashes and commit them:

```sh
sha256sum my-package-1.2.3-1.el9.x86_64.rpm >> scripts/checksums.sha256
```

`SKIP_CHECKSUM_VERIFY=1` bypasses the check for local testing. It warns once per
artifact; do not use it for a real deployment.

### Protocol translator socket permissions

Edge Core binds its protocol-translator socket, `/tmp/edge.sock`, using the
container's umask. The image default of `022` produces:

```
srwxr-xr-x. 1 root root  /tmp/edge.sock
```

Connecting to a unix socket requires **write** permission, so any protocol
translator that does not run as root is refused. The `dummy-device-app` from the
kaas-example runs as user `app` and fails with:

```
ERROR dummy_device_app: Failed to connect/register PT: Permission denied (os error 13)
```

The pod reports `Running` but never becomes ready - its `/health` endpoint is
plain HTTP and answers fine - so the liveness probe kills it on a loop.

`run-edge-core.sh` clears the umask before Edge Core binds, so the socket is
created `srwxrwxrwx` and non-root translators can connect. This is not new
exposure: the PT pods reach the socket by bind-mounting the host's `/tmp`, so
anything that can mount `/tmp` could already reach it. Set
`EDGE_CORE_SOCKET_UMASK` to tighten it if your translators run as a known uid.

If you start Edge Core by hand rather than with the script, wrap the entrypoint
the same way:

```sh
  --entrypoint /bin/bash \
  -d ghcr.io/izumanetworks/edge-core-dev:0.21.7 \
  -c 'umask 0000; exec /start_auto_dev_provision.sh "$@"' edge-core \
  --cbor-conf /usr/src/app/mbed-edge/edge-gw-config/kcm.cbor \
  ...
```

### Surviving a reboot

A freshly installed node can fail to come back from a reboot **entirely** - no
ssh, no getty, no edge services - rather than merely coming back degraded. Three
separate problems combine, and `install-thick-edge-services.sh` and
`run-edge-core.sh` now handle all of them. They are documented here because the
symptom gives no hint of the cause.

**1. A systemd ordering cycle deletes containerd.** `kube-router.service`,
`kube-router.path` and `kube-router-watcher.service` are all
`WantedBy=network.target`, and `kube-router.service` is `After=kubelet.service`.
That closes a loop:

```
network.target -> kube-router -> kubelet -> docker -> containerd -> network.target
```

systemd detects it and resolves it by dropping a job from the loop - which turns
out to be containerd's:

```
docker.service: Found ordering cycle on containerd.service/start
Job containerd.service/start deleted to break ordering cycle
```

containerd never starts, so Docker cannot run containers. These are application
services that need the container runtime, so the installer moves them to
`multi-user.target`.

**2. Edge Core does not come back.** With `--restart unless-stopped`, a container
that Docker stopped during host shutdown is treated as deliberately stopped and
is **not** restarted on the next boot. `run-edge-core.sh` uses `--restart always`.

**3. The identity wait then blocks the boot forever.**
`wait-for-pelion-identity.service` polls Edge Core's `/status` in a loop with no
timeout. It is `Type=oneshot` and `WantedBy=multi-user.target`, so until it
finishes, everything ordered after `multi-user.target` - including **sshd** -
never starts. Combined with (1) and (2) the host is unreachable indefinitely. The
installer adds a `TimeoutStartSec`, so a stuck identity wait leaves a failed unit
on a reachable host instead.

`coredns` is also given `Restart=on-failure`, because it binds `172.21.2.1:53`
and loses a cold-boot race against kube-router creating `kube-bridge`.

To check a node will survive a reboot:

```sh
# should print nothing
sudo journalctl -b | grep "ordering cycle"

# should all be active, and sshd must not be waiting on anything
systemctl is-active containerd docker kubelet kube-router coredns edge-proxy
docker inspect edge-core --format '{{.HostConfig.RestartPolicy.Name}}'   # always
```

#### pe-terminal: manual install and uninstall

pe-terminal is normally installed automatically by `install-thick-edge-services.sh`. If you need to install or reinstall it separately, run:

```sh
./scripts/install-pe-terminal.sh
```

> **Note:** pe-terminal requires edge-proxy to be active before it will function. Run `install-thick-edge-services.sh` first if you haven't already.

To uninstall pe-terminal, first preview what will be removed (dry-run):

```sh
./scripts/uninstall-pe-terminal.sh
```

Then apply the uninstall:

```sh
./scripts/uninstall-pe-terminal.sh --force
```

#### Cleanup (clean the box completely)

To fully clean this environment, stop/remove `edge-core`, delete identity/config folders, then run the cleanup script:

```sh
# Stop and remove edge-core if present
docker stop edge-core || true
docker rm edge-core || true

# Delete device identity/config folders (required for full reset/re-provision)
sudo rm -rf /var/lib/pelion/mbed/mcc_config
sudo rm -rf /var/lib/pelion/mbed/ec-kcm-conf

# Preview cleanup actions
./scripts/cleanup-edge-installation.sh

# Apply cleanup
./scripts/cleanup-edge-installation.sh --force
```

Also delete the development device from the Device Management Portal by following the official steps here: [Managing devices in your account - Deleting devices](https://developer.izumanetworks.com/docs/device-management/current/device-management/managing-devices-in-your-account.html#deleting-devices).

### Container orchestration example

Now you are ready to deploy your containerized application to your Edge device. Follow [these tutorials](https://developer.izumanetworks.com/docs/device-management-edge/2.6/container/deploying.html#create-a-kubeconfig-file) to set up kubectl to communicate with the Izuma kube-apiserver. [Here](https://developer.izumanetworks.com/docs/device-management-edge/2.6/tutorial/index.html#1-deploy-container) is a tutorial that deploys an example application, Tetris, on your Edge device.

See the [kaas-example](https://github.com/PelionIoT/mbed-edge-examples/tree/master/kaas-example) for deploying an application on the edge node. The example provides a mechanism to [template](https://github.com/PelionIoT/mbed-edge-examples/tree/master/kaas-example/k8s/templates) the definition files and uses a bash script, [render.sh](https://github.com/PelionIoT/mbed-edge-examples/tree/master/kaas-example/k8s), to render definition files for each edge node.

Note that KaaS is built using K8s version 1.13.2. We recommend using kubectl version <= 1.14.3. Here are the commands to get started on the dev machine:

```sh
curl -LO "https://storage.googleapis.com/kubernetes-release/release/v1.14.3/bin/linux/amd64/kubectl" # For Linux
# OR
curl -LO "https://storage.googleapis.com/kubernetes-release/release/v1.14.3/bin/darwin/amd64/kubectl" # For macOS

chmod +x ./kubectl

sudo mv ./kubectl /usr/local/bin/kubectl

kubectl version --client
```

### Troubleshooting

#### Connectivity tests to Izuma Device Management

```sh
nc -vz tcp-bootstrap.us-east-1.mbedcloud.com 443
telnet tcp-bootstrap.us-east-1.mbedcloud.com 443
nslookup tcp-bootstrap.us-east-1.mbedcloud.com

nc -vz tcp-lwm2m.us-east-1.mbedcloud.com 443
telnet tcp-lwm2m.us-east-1.mbedcloud.com 443
nslookup tcp-lwm2m.us-east-1.mbedcloud.com

sudo openssl s_client \
  -connect tcp-bootstrap.us-east-1.mbedcloud.com:443 \
  -cert /var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/bootstrap_dev.cert.pem \
  -key  /var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/bootstrap_dev.key.pem
```

#### Connectivity tests to Izuma Edge
```sh
nc -vz gateways.us-east-1.mbedcloud.com 443
telnet gateways.us-east-1.mbedcloud.com 443
nslookup gateways.us-east-1.mbedcloud.com

# If you bring your own LwM2M certificate, use your device cert/key to validate TLS connectivity
sudo openssl s_client \
  -connect gateways.us-east-1.mbedcloud.com:443 \
  -cert /var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/LwM2MDeviceCert.pem \
  -key  /var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/LwM2MDevicePrivateKey.pem
```

#### Client in reconnection mode SecureConnectionFailed

Please ensure that your Firewall is configured to allow outbound connections to the following hosts/IPs and ports to ensure proper device connectivity:

| Hostname                              | IP Address | Protocols                       | Ports     |
| ------------------------------------- | ---------- | ------------------------------- | --------- |
| **bootstrap.us-east-1.mbedcloud.com** | 38.97.2.36 | CoAP over UDP/TCP with DTLS/TLS | 5684, 443 |
| **tcp-bootstrap.us-east-1.mbedcloud.com** | 38.97.2.36 | CoAP over TCP with TLS | 443 |
| **udp-bootstrap.us-east-1.mbedcloud.com** | 38.97.2.36 | CoAP over UDP with DTLS | 5684 |
| **lwm2m.us-east-1.mbedcloud.com** | 38.97.2.37 | CoAP over UDP/TCP with DTLS/TLS | 5684, 443 |
| **tcp-lwm2m.us-east-1.mbedcloud.com** | 38.97.2.37 | CoAP over TCP with TLS | 443 |
| **udp-lwm2m.us-east-1.mbedcloud.com** | 38.97.2.37 | CoAP over UDP with DTLS | 5684 |
| **gateways.us-east-1.mbedcloud.com**  | 38.97.2.38 | HTTPS (TLS)                     | 443       |

Please allow both UDP and TCP on port 5684 and TCP on 443 on the CoAP endpoints.

- Bootstrap endpoint connects to Izuma's Bootstrap CoAP Server, which is used by devices during initial bootstrapping and provisioning. Devices contact this service to obtain configuration and credentials for further communication.

- LwM2M endpoint connects to Izuma's LwM2M CoAP Server,  which handles the Ongoing LwM2M (Lightweight M2M) device management traffic — such as device registration, heartbeats, reporting telemetry, and receiving commands, configurations, or firmware updates.

- Gateway endpoint connects to Izuma's Thick Edge services, which help manage/orchestrate containers at the edge, as well as system management features such as remote configuration, debug terminal, health metrics, and others.


#### CoreDNS bind error: "listen tcp 172.21.2.1:53: bind: cannot assign requested address"

Ensure the following:

1) Kube-router CNI is the lowest number to avoid conflicts
```sh
sudo mv /etc/cni/net.d/10-kuberouter.conflist /etc/cni/net.d/01-kuberouter.conflist
sudo systemctl restart kubelet kube-router coredns
```

2) Ensure the bridge IP exists
```sh
sudo ip addr add 172.21.2.1/24 dev kube-bridge || true
sudo ip link set kube-bridge up || true
```

Note: `kube-bridge` may remain down until a pod is scheduled.
