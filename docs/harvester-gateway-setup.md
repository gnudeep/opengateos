# Harvester Gateway Setup Guide

Deploy OpenGateOS as a gateway VM on Harvester HCI, providing DHCP, DNS, and NAT services across multiple VLANs.

## Network Topology

```
                          ┌─────────────────────┐
                          │   Upstream Router    │
                          │   203.0.113.1/24     │
                          └──────────┬───────────┘
                                     │
                              VLAN 100 (WAN)
                                     │
                          ┌──────────┴───────────┐
                          │   OpenGateOS Gateway  │
                          │   Harvester VM        │
                          │                       │
                          │   eth0  = WAN uplink  │
                          │   eth1  = VLAN trunk  │
                          │     ├─ vlan10 (Public)│
                          │     ├─ vlan20 (Private)│
                          │     ├─ vlan30 (System)│
                          │     └─ vlan40 (Data)  │
                          └──────────┬───────────┘
                                     │
                              802.1Q Trunk
                                     │
                    ┌────────────────┼────────────────┐
                    │                │                 │
              ┌─────┴─────┐  ┌──────┴──────┐  ┌──────┴──────┐
              │  VLAN 10  │  │   VLAN 20   │  │   VLAN 40   │
              │  Public   │  │   Private   │  │    Data     │
              │10.10.0/24 │  │ 10.20.0/24  │  │ 10.40.0/24  │
              └───────────┘  └─────────────┘  └─────────────┘
```

### Subnet Plan

| VLAN | Subnet         | Gateway      | Purpose                         | DHCP Range             |
|------|----------------|--------------|----------------------------------|------------------------|
| 100  | 203.0.113.0/24 | 203.0.113.1  | WAN uplink                       | —                      |
| 10   | 10.10.0.0/24   | 10.10.0.1    | Public services (web, ingress)   | 10.10.0.100–10.10.0.200|
| 20   | 10.20.0.0/24   | 10.20.0.1    | Private / application tier       | 10.20.0.100–10.20.0.200|
| 30   | 10.30.0.0/24   | 10.30.0.1    | System / platform services       | 10.30.0.100–10.30.0.200|
| 40   | 10.40.0.0/24   | 10.40.0.1    | Data tier (PostgreSQL, Redis)    | 10.40.0.100–10.40.0.200|

### Inter-VLAN Firewall Policy

| Source    | Destination | Policy                                       |
|-----------|-------------|----------------------------------------------|
| VLAN 10   | VLAN 20/30  | **Drop** — public isolated from private      |
| VLAN 10   | VLAN 40     | **Drop** — public cannot reach data tier     |
| VLAN 20   | VLAN 30     | **Accept** — app tier can reach platform     |
| VLAN 20   | VLAN 40     | **Accept** on ports 5432, 6379, 9092 only    |
| VLAN 30   | VLAN 40     | **Accept** on ports 5432, 6379, 9092 only    |
| VLAN 40   | WAN         | **Drop** — data tier has no internet access  |
| VLAN 20   | WAN         | **Accept** — outbound NAT via masquerade     |
| VLAN 30   | WAN         | **Accept** — outbound NAT via masquerade     |

---

## Harvester VM Setup

### Prerequisites

- Harvester HCI cluster running v1.2+
- VLAN-aware network configured on Harvester (ClusterNetwork + VLAN NetworkConfig)
- OpenGateOS ISO built (`make iso`) or qcow2 image (`make vm`)

### Step 1: Create VLAN Networks in Harvester

In the Harvester UI under **Networks > VM Networks**, create:

1. **wan-vlan100** — VLAN ID 100, attached to your uplink ClusterNetwork
2. **internal-trunk** — VLAN ID 0 (trunk mode), or create individual VLAN networks:
   - **vlan10-public** — VLAN ID 10
   - **vlan20-private** — VLAN ID 20
   - **vlan30-system** — VLAN ID 30
   - **vlan40-data** — VLAN ID 40

> **Trunk mode vs. individual VLANs:** If your Harvester network supports trunk ports (passing tagged traffic), use a single trunk interface on the VM. Otherwise, create separate Harvester VM Networks for each VLAN and attach them as individual NICs.

### Step 2: Create the Gateway VM

Create a VM in Harvester with the following specs:

| Setting        | Value                          |
|----------------|--------------------------------|
| Name           | `opengateos-gw`               |
| CPU            | 2 vCPU                         |
| Memory         | 2 GiB                          |
| Disk           | 10 GiB (virtio)                |
| Boot           | OpenGateOS ISO or qcow2 image  |
| Network (nic0) | `wan-vlan100`                  |
| Network (nic1) | `internal-trunk` (or individual VLAN networks) |

If using individual VLAN networks instead of trunk mode, add one NIC per VLAN:

| NIC  | Network          | Maps to  |
|------|------------------|----------|
| nic0 | wan-vlan100      | eth0     |
| nic1 | vlan10-public    | eth1     |
| nic2 | vlan20-private   | eth2     |
| nic3 | vlan30-system    | eth3     |
| nic4 | vlan40-data      | eth4     |

### Step 3: Interface Mapping

After booting the VM, verify interface names:

```bash
ip link show
```

Map the interfaces:

- **eth0** — WAN uplink (VLAN 100, gets 203.0.113.x address)
- **eth1** — Trunk interface (carries tagged VLAN 10/20/30/40 traffic)

The gateway config creates VLAN sub-interfaces on eth1:

```
eth1.10 → vlan10 (10.10.0.1/24)
eth1.20 → vlan20 (10.20.0.1/24)
eth1.30 → vlan30 (10.30.0.1/24)
eth1.40 → vlan40 (10.40.0.1/24)
```

---

## Applying the Configuration

The ready-to-use configuration is at `configs/harvester-gateway.json` in this repo. It includes interfaces, VLANs, DHCP, DNS, NAT, and firewall rules.

### Option A: Load config file directly

Copy the config to the gateway VM and load it:

```bash
# On the gateway VM
scp user@git-server:opengateos/configs/harvester-gateway.json /tmp/gateway.json
cp /tmp/gateway.json /config/candidate/config.json
routercli compare    # Review changes
routercli commit --comment "Initial harvester gateway config"
routercli save       # Persist to boot config
```

### Option B: Use the GitOps workflow

See [GitOps Workflow](gitops-workflow.md) for the automated pull-and-apply process using `scripts/apply-config.sh`.

---

## DHCP Configuration

The gateway runs dnsmasq to provide DHCP on each VLAN subnet. The `services.dhcp` section in the config defines pools:

```json
"dhcp": {
  "vlan10": {
    "interface": "vlan10",
    "range_start": "10.10.0.100",
    "range_end": "10.10.0.200",
    "lease_time": "12h",
    "gateway": "10.10.0.1",
    "dns_server": "10.10.0.1"
  }
}
```

Each VLAN gets its own DHCP pool with:
- 101 addresses (.100–.200) for dynamic allocation
- 12-hour lease time
- Gateway pointing to the OpenGateOS VLAN interface
- DNS server pointing to the local DNS forwarder

### Static DHCP Reservations

Add static mappings under each pool for hosts that need fixed IPs:

```json
"static_mappings": {
  "k8s-node-01": {
    "mac": "aa:bb:cc:dd:ee:01",
    "ip": "10.20.0.10"
  }
}
```

---

## DNS Configuration

The gateway runs dnsmasq as a local DNS forwarder. The `services.dns-forwarding` section configures:

```json
"dns-forwarding": {
  "listen_addresses": ["10.10.0.1", "10.20.0.1", "10.30.0.1", "10.40.0.1"],
  "upstream_servers": ["1.1.1.1", "8.8.8.8"],
  "cache_size": 1000,
  "domain": "infra.local"
}
```

- Listens on all VLAN gateway addresses
- Forwards to Cloudflare and Google DNS
- Caches up to 1000 entries
- Resolves `*.infra.local` locally for internal hosts

---

## NAT / Masquerade

Outbound traffic from internal VLANs is NATed via the WAN interface:

```json
"nat": {
  "masquerade-outbound": {
    "oif": "eth0",
    "action": "masquerade"
  }
}
```

This generates an nftables masquerade rule on eth0. All traffic leaving via eth0 gets source-NATed to the WAN IP address.

---

## Firewall Rules

The config includes both input (to the gateway itself) and forward (between VLANs) rules.

### Input Rules

| Rule                | Interface | Protocol | Ports     | Action |
|---------------------|-----------|----------|-----------|--------|
| allow-ssh-mgmt      | eth0      | TCP      | 22        | Accept |
| allow-dns           | all VLANs | UDP/TCP  | 53        | Accept |
| allow-dhcp          | all VLANs | UDP      | 67        | Accept |
| allow-icmp          | —         | ICMP     | echo      | Accept |

### Forward Rules

| Rule                       | From    | To      | Protocol | Ports            | Action |
|----------------------------|---------|---------|----------|------------------|--------|
| deny-public-to-private     | vlan10  | vlan20  | —        | —                | Drop   |
| deny-public-to-system      | vlan10  | vlan30  | —        | —                | Drop   |
| deny-public-to-data        | vlan10  | vlan40  | —        | —                | Drop   |
| allow-private-to-system    | vlan20  | vlan30  | —        | —                | Accept |
| allow-private-to-data-db   | vlan20  | vlan40  | TCP      | 5432,6379,9092   | Accept |
| allow-system-to-data-db    | vlan30  | vlan40  | TCP      | 5432,6379,9092   | Accept |
| deny-data-outbound         | vlan40  | eth0    | —        | —                | Drop   |
| allow-private-internet     | vlan20  | eth0    | —        | —                | Accept |
| allow-system-internet      | vlan30  | eth0    | —        | —                | Accept |

---

## Verification

After applying the config, verify each component:

```bash
# Interfaces and VLANs
ip addr show
ip link show type vlan

# DHCP — test from a client VM on VLAN 20
dhclient -v eth0  # should get 10.20.0.x

# DNS — query the gateway
dig @10.20.0.1 example.com

# NAT — from a VLAN 20 client
curl -I https://example.com

# Firewall rules
nft list ruleset

# Routing
ip route show
ip route show table 100  # vrf-public
```

---

## Troubleshooting

### VLAN traffic not reaching the VM

- Verify Harvester VM Network has the correct VLAN ID
- Check that the physical switch port to the Harvester node is configured as a trunk carrying the required VLANs
- Run `tcpdump -i eth1 -e vlan` on the gateway to see tagged frames

### DHCP not responding

- Ensure dnsmasq is running: `systemctl status dnsmasq`
- Check that the DHCP interface matches the VLAN interface name in config
- Verify the firewall allows UDP port 67 on the VLAN interfaces

### No internet from internal VLANs

- Verify NAT masquerade rule exists: `nft list table ip nat`
- Check IP forwarding: `sysctl net.ipv4.ip_forward` (should be 1)
- Verify the default route exists in the appropriate VRF: `ip route show table 100`
