# OpenGateOS

A minimal Ubuntu-based network router operating system with VyOS-like configuration management. OpenGateOS builds a bootable ISO (and optional qcow2 VM image) that turns commodity hardware or virtual machines into a full-featured network router.

## Features

- **VyOS-style configuration management** — edit, compare, commit, save, rollback workflow
- **Multi-interface support** — Ethernet, VLANs (802.1Q), loopback
- **VRF (Virtual Routing and Forwarding)** — network segmentation with policy routing
- **Dynamic routing** — BGP and OSPF via FRRouting (FRR)
- **Firewall** — nftables-based firewall with NAT/masquerade
- **VPN** — WireGuard, StrongSwan (IPsec), OpenVPN
- **Config rollback** — automatic rollback with timed confirmation (commit-confirm)
- **Config archiving** — up to 50 revision history with diff support
- **Boot persistence** — dedicated config partition survives reboots
- **System hardening** — optimized sysctl tuning for routing workloads

## Quick Start

### Build the ISO

```bash
# Requires Ubuntu 22.04+ build host with root access
sudo make iso
```

### Build ISO + VM Image

```bash
sudo make vm
```

### Test in QEMU

```bash
# Test the VM image (4 NICs, SSH forwarded to localhost:2222)
make test-vm

# Test the ISO
make test-iso
```

### Build Options

| Variable | Default | Description |
|---|---|---|
| `DISTRO_NAME` | NetRouter OS | Distribution name |
| `DISTRO_VERSION` | 1.0.0 | Version string |
| `ARCH` | amd64 | Target architecture |
| `UBUNTU_RELEASE` | noble | Ubuntu base release (24.04) |
| `OUTPUT_DIR` | ./output | Output directory |

```bash
sudo make iso DISTRO_NAME="MyRouter" DISTRO_VERSION="2.0"
```

## Configuration Management

OpenGateOS uses a VyOS-like configuration workflow via the `routercli` command.

### Workflow

```bash
routercli edit                              # Start config session
routercli set <path> <value>                # Set a value
routercli delete <path>                     # Delete a node
routercli show [--path <path>]              # Show candidate config
routercli compare                           # Diff active vs candidate
routercli commit --comment "description"    # Apply changes
routercli save                              # Persist to boot config
```

### Example: Configure an Interface with VLAN

```bash
routercli edit
routercli set interfaces.ethernet.eth0.address "10.0.0.1/24"
routercli set interfaces.vlan.vlan100.id 100
routercli set interfaces.vlan.vlan100.link eth1
routercli set interfaces.vlan.vlan100.address "10.100.0.1/24"
routercli compare
routercli commit --comment "added vlan100" --confirm 5
# verify connectivity ...
routercli confirm
routercli save
```

### Commit-Confirm (Safe Deployments)

Apply changes with automatic rollback if not confirmed within N minutes:

```bash
routercli commit --confirm 10    # Auto-rollback in 10 minutes
# test connectivity ...
routercli confirm                # Cancel rollback, keep changes
```

### Rollback

```bash
routercli history               # Show revision history
routercli rollback 1            # Rollback to previous revision
```

## Project Structure

```
opengateos/
├── build-router-iso.sh     # ISO/VM image build script
├── config_manager.py       # Configuration management engine
├── routercli               # CLI wrapper for config_manager.py
├── router-config.service   # systemd service for boot-time config loading
├── example-config.json     # Example router configuration
└── Makefile                # Build targets (iso, vm, test-vm, clean)
```

## Default Credentials

| User | Password |
|---|---|
| `admin` | `admin` |
| `root` | `router` |

**Change these immediately after first boot.**

## Requirements

### Build Host

- Ubuntu 22.04+
- Root access (sudo)
- ~10 GB free disk space
- Internet access (for package downloads)

### Runtime

The built image includes:
- FRRouting (BGP, OSPF, static routes)
- nftables (firewall)
- iproute2 (interfaces, VLANs, VRFs)
- WireGuard, StrongSwan, OpenVPN
- dnsmasq, ISC DHCP server
- LLDP daemon
- SSH server

## License

This project is open source.
