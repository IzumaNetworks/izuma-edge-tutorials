## Getting started with Izuma Edge on Ubuntu 22.04/24.04

This guide walks you through running and managing your Edge application in a container using Izuma's KaaS (Kubernetes‑as‑a‑Service). You will install the required components on an Ubuntu 22.04/24.04 host. Edge Core (mbed-edge) runs in a Docker container, while components such as edge-proxy, kubelet, and pe-utils run natively on the host as Debian packages.


### Requirements

- Ubuntu 22.04 or 24.04 machine (tested on 2 CPU, 2 GB RAM, 16 GB disk). Validated these steps against machine - 

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

Run the following script on your Ubuntu host. It will:
- Install Docker and common utilities
- Configure cgroup v1 (required by the Izuma Edge kubelet)
- Prompt for reboot when done

```sh
./scripts/prereqs.sh
```

After reboot, verify:
```sh
stat -fc %T /sys/fs/cgroup | grep -q cgroup2 && echo "cgroup v2" || echo "cgroup v1"
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

Replace placeholders and run:
```sh
## When re-provisioning as a new device, clean up old credentials
# sudo rm -rf /var/lib/pelion/mbed/mcc_config
# sudo rm -rf /var/lib/pelion/mbed/ec-kcm-conf

sudo mkdir -p /var/lib/pelion/mbed
mkdir -p /tmp

ACCOUNT_ID="replace_with_account_id"
ACCESS_TOKEN="replace_with_access_key"

# Rotates logs after 50MB, keeping 10 files (~500MB total)
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
  -d ghcr.io/izumanetworks/edge-core-dev:0.21.6 \
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
  "lwm2m-server-uri": "..."
}
```

View Edge Core logs:
```sh
docker logs edge-core
```

#### 2) Install thick edge services (Debian packages)

Run the following script to install services required for Izuma's container orchestration solution: edge-proxy, kubelet, pe-utils, kube-router and coredns. This will download the 
```sh
./scripts/install-thick-edge-services.sh
```

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
```

View logs:
```sh
sudo journalctl -u kubelet -n 200 --no-pager 
sudo journalctl -u edge-proxy -n 200 --no-pager
sudo journalctl -u coredns -n 200 --no-pager
sudo journalctl -u kube-router -n 200 --no-pager
```

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

#### Connectivity tests to Izuma gateways
```sh
nc -vz gateways.us-east-1.mbedcloud.com 443
telnet gateways.us-east-1.mbedcloud.com 443
nslookup gateways.us-east-1.mbedcloud.com

# Use your device cert/key to validate TLS connectivity
sudo openssl s_client \
  -connect gateways.us-east-1.mbedcloud.com:443 \
  -cert /var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/LwM2MDeviceCert.pem \
  -key  /var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/LwM2MDevicePrivateKey.pem
```

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
