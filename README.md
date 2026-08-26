## Getting started with Izuma Edge on Ubuntu 22.04/24.04 and AlmaLinux 9

This guide walks you through running and managing your Edge application in a container using Izuma's KaaS (Kubernetes‑as‑a‑Service). Edge Core (mbed-edge) runs in a Docker container, while components such as edge-proxy, kubelet, and pe-utils run natively on the host as distribution packages.

The scripts in `scripts/` detect the host distribution and use the right package manager:

| Host | Packages | Package manager |
| --- | --- | --- |
| Ubuntu 20.04 / 22.04 / 24.04 | `.deb` | `apt` |
| AlmaLinux 9, Rocky Linux 9, RHEL 9, CentOS Stream 9 | `.rpm` | `dnf` |

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
| `SELINUX_SET_PERMISSIVE=1` | Set SELinux to permissive rather than only warning about it (RHEL 9 derivatives) |

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
