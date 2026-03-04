#!/usr/bin/env python3
"""
VyOS-like Configuration Management System
Supports: edit → compare → commit → save → rollback
"""

import json
import os
import sys
import shutil
import subprocess
import hashlib
import difflib
import datetime
import argparse
from pathlib import Path
from copy import deepcopy

# --- Paths ---
CONFIG_DIR = "/config"
ACTIVE_CONFIG = f"{CONFIG_DIR}/active/config.json"
CANDIDATE_CONFIG = f"{CONFIG_DIR}/candidate/config.json"
ARCHIVE_DIR = f"{CONFIG_DIR}/archive"
BOOT_CONFIG = f"{CONFIG_DIR}/boot/config.json"
LOCK_FILE = f"{CONFIG_DIR}/.config.lock"
MAX_ARCHIVES = 50

# --- Template: Default empty config ---
DEFAULT_CONFIG = {
    "system": {
        "hostname": "router",
        "domain": "local",
        "dns": {
            "nameservers": ["1.1.1.1", "8.8.8.8"]
        },
        "ntp": {
            "servers": ["pool.ntp.org"]
        },
        "syslog": {
            "global": {"facility": "all", "level": "info"}
        },
        "users": {}
    },
    "interfaces": {
        "ethernet": {},
        "vlan": {},
        "loopback": {
            "lo": {"address": ["127.0.0.1/8"]}
        }
    },
    "vrf": {},
    "protocols": {
        "static": {"routes": {}},
        "bgp": {},
        "ospf": {}
    },
    "firewall": {
        "zones": {},
        "rules": {},
        "nat": {}
    },
    "services": {
        "ssh": {"port": 22, "enabled": True},
        "dhcp": {},
        "dns-forwarding": {}
    },
    "vpn": {
        "wireguard": {},
        "ipsec": {}
    }
}


class ConfigLock:
    """Prevent concurrent config modifications."""
    def __enter__(self):
        if os.path.exists(LOCK_FILE):
            pid = open(LOCK_FILE).read().strip()
            raise RuntimeError(f"Config locked by PID {pid}. Use 'discard' to force unlock.")
        with open(LOCK_FILE, "w") as f:
            f.write(str(os.getpid()))
        return self

    def __exit__(self, *args):
        if os.path.exists(LOCK_FILE):
            os.remove(LOCK_FILE)


class ConfigManager:
    def __init__(self):
        self._ensure_dirs()

    def _ensure_dirs(self):
        for d in [f"{CONFIG_DIR}/active", f"{CONFIG_DIR}/candidate",
                  ARCHIVE_DIR, f"{CONFIG_DIR}/boot"]:
            os.makedirs(d, exist_ok=True)

        if not os.path.exists(ACTIVE_CONFIG):
            self._write_json(ACTIVE_CONFIG, DEFAULT_CONFIG)
        if not os.path.exists(BOOT_CONFIG):
            shutil.copy2(ACTIVE_CONFIG, BOOT_CONFIG)

    def _read_json(self, path):
        with open(path) as f:
            return json.load(f)

    def _write_json(self, path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(data, f, indent=2)

    def _config_hash(self, data):
        return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()[:12]

    # ---- Core Operations ----

    def edit_start(self):
        """Start a config session — copy active to candidate."""
        shutil.copy2(ACTIVE_CONFIG, CANDIDATE_CONFIG)
        print("Configuration session started. Edit candidate config.")
        print(f"  Candidate: {CANDIDATE_CONFIG}")

    def set_value(self, path: str, value):
        """
        Set a value in candidate config.
        Path format: "interfaces.ethernet.eth0.address" 
        """
        config = self._read_json(CANDIDATE_CONFIG)
        keys = path.split(".")
        node = config
        for key in keys[:-1]:
            if key not in node:
                node[key] = {}
            node = node[key]

        # Auto-parse value types
        if isinstance(value, str):
            if value.lower() == "true":
                value = True
            elif value.lower() == "false":
                value = False
            elif value.isdigit():
                value = int(value)
            # If comma-separated, treat as list
            elif "," in value:
                value = [v.strip() for v in value.split(",")]

        node[keys[-1]] = value
        self._write_json(CANDIDATE_CONFIG, config)
        print(f"  SET {path} = {value}")

    def delete_value(self, path: str):
        """Delete a node from candidate config."""
        config = self._read_json(CANDIDATE_CONFIG)
        keys = path.split(".")
        node = config
        for key in keys[:-1]:
            if key not in node:
                print(f"  Path not found: {path}")
                return
            node = node[key]
        if keys[-1] in node:
            del node[keys[-1]]
            self._write_json(CANDIDATE_CONFIG, config)
            print(f"  DELETED {path}")
        else:
            print(f"  Path not found: {path}")

    def show_candidate(self, path: str = None):
        """Show candidate config (optionally at a specific path)."""
        config = self._read_json(CANDIDATE_CONFIG)
        if path:
            for key in path.split("."):
                config = config.get(key, {})
        print(json.dumps(config, indent=2))

    def compare(self):
        """Show diff between active and candidate."""
        active = json.dumps(self._read_json(ACTIVE_CONFIG), indent=2).splitlines()
        candidate = json.dumps(self._read_json(CANDIDATE_CONFIG), indent=2).splitlines()

        diff = difflib.unified_diff(
            active, candidate,
            fromfile="active", tofile="candidate",
            lineterm=""
        )
        output = "\n".join(diff)
        if output:
            print(output)
        else:
            print("No changes.")
        return bool(output)

    def commit(self, comment: str = "", confirm_minutes: int = 0):
        """
        Apply candidate config to system.
        confirm_minutes: if >0, auto-rollback after N minutes unless confirmed.
        """
        if not os.path.exists(CANDIDATE_CONFIG):
            print("No candidate config. Run 'edit' first.")
            return False

        candidate = self._read_json(CANDIDATE_CONFIG)
        active = self._read_json(ACTIVE_CONFIG)

        if self._config_hash(candidate) == self._config_hash(active):
            print("No changes to commit.")
            return True

        # Validate before applying
        errors = self._validate(candidate)
        if errors:
            print("Validation errors:")
            for e in errors:
                print(f"  ✗ {e}")
            return False

        # Archive current active
        self._archive(active, comment)

        # Apply to system
        print("Applying configuration...")
        success = self._apply(candidate)

        if success:
            self._write_json(ACTIVE_CONFIG, candidate)
            print(f"Commit successful. [{self._config_hash(candidate)}]")

            if confirm_minutes > 0:
                print(f"⚠ Auto-rollback in {confirm_minutes} minutes unless confirmed.")
                self._schedule_rollback(confirm_minutes)
            return True
        else:
            print("Commit FAILED. Rolling back...")
            self._apply(active)
            return False

    def confirm(self):
        """Confirm a pending commit (cancel auto-rollback)."""
        subprocess.run(["systemctl", "stop", "config-rollback.timer"],
                       capture_output=True)
        print("Commit confirmed. Auto-rollback cancelled.")

    def save(self):
        """Save active config as boot config."""
        shutil.copy2(ACTIVE_CONFIG, BOOT_CONFIG)
        print(f"Configuration saved to {BOOT_CONFIG}")

    def discard(self):
        """Discard candidate changes."""
        if os.path.exists(CANDIDATE_CONFIG):
            os.remove(CANDIDATE_CONFIG)
        if os.path.exists(LOCK_FILE):
            os.remove(LOCK_FILE)
        print("Candidate config discarded.")

    def rollback(self, revision: int = 1):
        """Rollback to a previous config revision."""
        archives = sorted(Path(ARCHIVE_DIR).glob("*.json"), reverse=True)
        if revision < 1 or revision > len(archives):
            print(f"Invalid revision. Available: 1-{len(archives)}")
            return False

        archive_path = archives[revision - 1]
        archived = self._read_json(str(archive_path))

        print(f"Rolling back to: {archive_path.name}")

        # Show what will change
        active = json.dumps(self._read_json(ACTIVE_CONFIG), indent=2).splitlines()
        target = json.dumps(archived, indent=2).splitlines()
        diff = "\n".join(difflib.unified_diff(active, target,
                                               fromfile="current", tofile="rollback"))
        if diff:
            print(diff)

        # Archive current, then apply rollback
        self._archive(self._read_json(ACTIVE_CONFIG), "pre-rollback")
        success = self._apply(archived)
        if success:
            self._write_json(ACTIVE_CONFIG, archived)
            print("Rollback successful.")
            return True
        return False

    def history(self, count: int = 10):
        """Show config archive history."""
        archives = sorted(Path(ARCHIVE_DIR).glob("*.json"), reverse=True)[:count]
        print(f"{'Rev':<5} {'Timestamp':<25} {'Hash':<14} {'Comment'}")
        print("-" * 70)
        for i, a in enumerate(archives, 1):
            meta = a.stem  # timestamp_hash_comment
            parts = meta.split("_", 2)
            ts = parts[0] if len(parts) > 0 else "?"
            h = parts[1] if len(parts) > 1 else "?"
            comment = parts[2] if len(parts) > 2 else ""
            # Format timestamp
            try:
                dt = datetime.datetime.strptime(ts, "%Y%m%d%H%M%S")
                ts_fmt = dt.strftime("%Y-%m-%d %H:%M:%S")
            except ValueError:
                ts_fmt = ts
            print(f"{i:<5} {ts_fmt:<25} {h:<14} {comment}")

    # ---- Internal Methods ----

    def _validate(self, config):
        """Validate config before commit."""
        errors = []

        # Check interfaces have addresses
        for iface_type in ["ethernet", "vlan"]:
            for name, iconf in config.get("interfaces", {}).get(iface_type, {}).items():
                if iconf.get("enabled", True) and not iconf.get("address") and not iconf.get("dhcp"):
                    # Warning only, not error
                    pass

        # Check VRFs reference valid interfaces
        for vrf_name, vrf_conf in config.get("vrf", {}).items():
            table = vrf_conf.get("table")
            if not table or not isinstance(table, int):
                errors.append(f"VRF '{vrf_name}' missing valid routing table number")
            for iface in vrf_conf.get("interfaces", []):
                found = False
                for itype in ["ethernet", "vlan", "loopback"]:
                    if iface in config.get("interfaces", {}).get(itype, {}):
                        found = True
                        break
                if not found:
                    errors.append(f"VRF '{vrf_name}' references unknown interface '{iface}'")

        # Check BGP has AS number
        for vrf, bgp_conf in config.get("protocols", {}).get("bgp", {}).items():
            if not bgp_conf.get("asn"):
                errors.append(f"BGP in '{vrf}' missing ASN")

        return errors

    def _archive(self, config, comment=""):
        """Archive a config revision."""
        ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
        h = self._config_hash(config)
        safe_comment = comment.replace(" ", "-").replace("/", "")[:30] if comment else ""
        filename = f"{ts}_{h}_{safe_comment}.json"
        self._write_json(f"{ARCHIVE_DIR}/{filename}", config)

        # Prune old archives
        archives = sorted(Path(ARCHIVE_DIR).glob("*.json"), reverse=True)
        for old in archives[MAX_ARCHIVES:]:
            old.unlink()

    def _apply(self, config):
        """Apply config to the running system. Returns True on success."""
        try:
            self._apply_system(config.get("system", {}))
            self._apply_interfaces(config.get("interfaces", {}))
            self._apply_vrfs(config.get("vrf", {}))
            self._apply_routing(config.get("protocols", {}), config.get("vrf", {}))
            self._apply_firewall(config.get("firewall", {}))
            self._apply_services(config.get("services", {}))
            return True
        except Exception as e:
            print(f"  Apply error: {e}")
            return False

    def _apply_system(self, sys_conf):
        """Apply system-level config."""
        hostname = sys_conf.get("hostname", "router")
        subprocess.run(["hostnamectl", "set-hostname", hostname], check=True)

        # DNS
        resolv = ""
        if sys_conf.get("domain"):
            resolv += f"search {sys_conf['domain']}\n"
        for ns in sys_conf.get("dns", {}).get("nameservers", []):
            resolv += f"nameserver {ns}\n"
        if resolv:
            with open("/etc/resolv.conf", "w") as f:
                f.write(resolv)
        print(f"  ✓ System: hostname={hostname}")

    def _apply_interfaces(self, iface_conf):
        """Apply interface configuration via iproute2."""
        # Ethernet
        for name, conf in iface_conf.get("ethernet", {}).items():
            if not conf.get("enabled", True):
                subprocess.run(["ip", "link", "set", name, "down"])
                continue
            subprocess.run(["ip", "link", "set", name, "up"])
            if conf.get("mtu"):
                subprocess.run(["ip", "link", "set", name, "mtu", str(conf["mtu"])])

            # Flush existing addresses and set new ones
            subprocess.run(["ip", "addr", "flush", "dev", name])
            for addr in conf.get("address", []):
                subprocess.run(["ip", "addr", "add", addr, "dev", name])
            print(f"  ✓ Interface: {name} {conf.get('address', [])}")

        # VLANs
        for name, conf in iface_conf.get("vlan", {}).items():
            parent = conf.get("link")
            vlan_id = conf.get("id")
            if not parent or not vlan_id:
                continue

            # Remove if exists, then recreate
            subprocess.run(["ip", "link", "del", name], capture_output=True)
            subprocess.run(["ip", "link", "add", "link", parent,
                           "name", name, "type", "vlan", "id", str(vlan_id)])
            subprocess.run(["ip", "link", "set", name, "up"])
            if conf.get("mtu"):
                subprocess.run(["ip", "link", "set", name, "mtu", str(conf["mtu"])])

            for addr in conf.get("address", []):
                subprocess.run(["ip", "addr", "add", addr, "dev", name])
            print(f"  ✓ VLAN: {name} (id={vlan_id}, parent={parent}) {conf.get('address', [])}")

    def _apply_vrfs(self, vrf_conf):
        """Apply VRF configuration."""
        # Get existing VRFs
        result = subprocess.run(["ip", "vrf", "show"], capture_output=True, text=True)
        existing_vrfs = set()
        for line in result.stdout.strip().splitlines()[1:]:  # skip header
            parts = line.split()
            if parts:
                existing_vrfs.add(parts[0])

        for name, conf in vrf_conf.items():
            table = conf.get("table")
            if not table:
                continue

            # Create VRF if not exists
            if name not in existing_vrfs:
                subprocess.run(["ip", "link", "add", name, "type", "vrf", "table", str(table)])
            subprocess.run(["ip", "link", "set", name, "up"])

            # Assign interfaces
            for iface in conf.get("interfaces", []):
                subprocess.run(["ip", "link", "set", iface, "master", name])

            # Policy rules
            for rule in conf.get("rules", []):
                subprocess.run(["ip", "rule", "add"] + rule.split() + ["lookup", str(table)],
                              capture_output=True)

            print(f"  ✓ VRF: {name} (table={table}) interfaces={conf.get('interfaces', [])}")

    def _apply_routing(self, proto_conf, vrf_conf):
        """Generate and apply FRR config."""
        frr_lines = [
            "frr version 10.0",
            "frr defaults traditional",
            "log syslog informational",
            "!"
        ]

        # Static routes
        static = proto_conf.get("static", {}).get("routes", {})
        for dest, route in static.items():
            vrf_str = f" vrf {route['vrf']}" if route.get("vrf") else ""
            frr_lines.append(f"ip route {dest} {route['next_hop']}{vrf_str}")

        # OSPF
        for vrf_name, ospf_conf in proto_conf.get("ospf", {}).items():
            vrf_str = f" vrf {vrf_name}" if vrf_name != "default" else ""
            frr_lines.append(f"router ospf{vrf_str}")
            if ospf_conf.get("router_id"):
                frr_lines.append(f" ospf router-id {ospf_conf['router_id']}")
            for net in ospf_conf.get("networks", []):
                frr_lines.append(f" network {net['prefix']} area {net['area']}")
            frr_lines.append("!")

        # BGP
        for vrf_name, bgp_conf in proto_conf.get("bgp", {}).items():
            asn = bgp_conf.get("asn")
            if not asn:
                continue
            vrf_str = f" vrf {vrf_name}" if vrf_name != "default" else ""
            frr_lines.append(f"router bgp {asn}{vrf_str}")
            if bgp_conf.get("router_id"):
                frr_lines.append(f" bgp router-id {bgp_conf['router_id']}")
            for neighbor in bgp_conf.get("neighbors", []):
                frr_lines.append(f" neighbor {neighbor['address']} remote-as {neighbor['asn']}")
            frr_lines.append(" address-family ipv4 unicast")
            for r in bgp_conf.get("redistribute", []):
                frr_lines.append(f"  redistribute {r}")
            # Route leaking
            for imp in bgp_conf.get("import_vrf", []):
                frr_lines.append(f"  import vrf {imp}")
            frr_lines.append(" exit-address-family")
            frr_lines.append("!")

        frr_config = "\n".join(frr_lines) + "\n"
        with open("/etc/frr/frr.conf", "w") as f:
            f.write(frr_config)

        subprocess.run(["systemctl", "reload", "frr"], capture_output=True)
        print(f"  ✓ Routing: FRR config applied ({len(frr_lines)} lines)")

    def _apply_firewall(self, fw_conf):
        """Generate and apply nftables config."""
        nft_lines = [
            "#!/usr/sbin/nft -f",
            "flush ruleset",
            ""
        ]

        # Build filter table
        nft_lines.append("table inet filter {")

        # Input chain
        nft_lines.append("    chain input {")
        nft_lines.append("        type filter hook input priority 0; policy drop;")
        nft_lines.append("        ct state established,related accept")
        nft_lines.append("        iif lo accept")
        for rule_name, rule in fw_conf.get("rules", {}).get("input", {}).items():
            nft_lines.append(f"        # {rule_name}")
            nft_lines.append(f"        {self._build_nft_rule(rule)}")
        nft_lines.append("    }")

        # Forward chain
        nft_lines.append("    chain forward {")
        nft_lines.append("        type filter hook forward priority 0; policy drop;")
        nft_lines.append("        ct state established,related accept")
        for rule_name, rule in fw_conf.get("rules", {}).get("forward", {}).items():
            nft_lines.append(f"        # {rule_name}")
            nft_lines.append(f"        {self._build_nft_rule(rule)}")
        nft_lines.append("    }")
        nft_lines.append("}")

        # NAT table
        if fw_conf.get("nat"):
            nft_lines.append("")
            nft_lines.append("table ip nat {")
            nft_lines.append("    chain postrouting {")
            nft_lines.append("        type nat hook postrouting priority 100;")
            for rule_name, rule in fw_conf.get("nat", {}).items():
                nft_lines.append(f"        # {rule_name}")
                nft_lines.append(f"        {self._build_nft_nat(rule)}")
            nft_lines.append("    }")
            nft_lines.append("}")

        nft_config = "\n".join(nft_lines) + "\n"
        with open("/etc/nftables.conf", "w") as f:
            f.write(nft_config)

        subprocess.run(["nft", "-f", "/etc/nftables.conf"], capture_output=True)
        print(f"  ✓ Firewall: nftables config applied")

    def _build_nft_rule(self, rule):
        """Build a single nftables rule from config dict."""
        parts = []
        if rule.get("iif"):
            parts.append(f'iif "{rule["iif"]}"')
        if rule.get("oif"):
            parts.append(f'oif "{rule["oif"]}"')
        if rule.get("protocol"):
            parts.append(f'{rule["protocol"]}')
        if rule.get("dport"):
            ports = rule["dport"] if isinstance(rule["dport"], str) else str(rule["dport"])
            parts.append(f'dport {{ {ports} }}')
        if rule.get("saddr"):
            parts.append(f'ip saddr {rule["saddr"]}')
        parts.append(rule.get("action", "accept"))
        return " ".join(parts)

    def _build_nft_nat(self, rule):
        """Build NAT rule."""
        parts = []
        if rule.get("oif"):
            parts.append(f'oif "{rule["oif"]}"')
        if rule.get("saddr"):
            parts.append(f'ip saddr {rule["saddr"]}')
        parts.append(rule.get("action", "masquerade"))
        return " ".join(parts)

    def _apply_services(self, svc_conf):
        """Apply service configurations."""
        # SSH
        ssh = svc_conf.get("ssh", {})
        if ssh.get("enabled", True):
            port = ssh.get("port", 22)
            # Update sshd_config port
            subprocess.run(["sed", "-i", f"s/^#*Port .*/Port {port}/",
                          "/etc/ssh/sshd_config"], capture_output=True)
            subprocess.run(["systemctl", "enable", "--now", "ssh"], capture_output=True)
        print(f"  ✓ Services: SSH port={ssh.get('port', 22)}")

    def _schedule_rollback(self, minutes):
        """Schedule automatic rollback via systemd timer."""
        service = """[Unit]
Description=Auto rollback config

[Service]
Type=oneshot
ExecStart=/usr/local/bin/routercli rollback 1
"""
        timer = f"""[Unit]
Description=Config rollback timer

[Timer]
OnActiveSec={minutes}min
AccuracySec=1s

[Install]
WantedBy=timers.target
"""
        with open("/etc/systemd/system/config-rollback.service", "w") as f:
            f.write(service)
        with open("/etc/systemd/system/config-rollback.timer", "w") as f:
            f.write(timer)
        subprocess.run(["systemctl", "daemon-reload"])
        subprocess.run(["systemctl", "start", "config-rollback.timer"])


# ---- CLI Entrypoint ----

def main():
    parser = argparse.ArgumentParser(description="Router Configuration Manager")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("edit", help="Start config session")
    sub.add_parser("show", help="Show candidate config").add_argument("--path", default=None)
    sub.add_parser("compare", help="Compare active vs candidate")

    set_p = sub.add_parser("set", help="Set config value")
    set_p.add_argument("path", help="Config path (dot-separated)")
    set_p.add_argument("value", help="Value to set")

    del_p = sub.add_parser("delete", help="Delete config value")
    del_p.add_argument("path", help="Config path (dot-separated)")

    commit_p = sub.add_parser("commit", help="Apply candidate config")
    commit_p.add_argument("--comment", default="", help="Commit message")
    commit_p.add_argument("--confirm", type=int, default=0, help="Auto-rollback minutes")

    sub.add_parser("confirm", help="Confirm pending commit")
    sub.add_parser("save", help="Save active config to boot")
    sub.add_parser("discard", help="Discard candidate config")

    rb = sub.add_parser("rollback", help="Rollback to previous revision")
    rb.add_argument("revision", type=int, default=1, nargs="?")

    hist = sub.add_parser("history", help="Show config history")
    hist.add_argument("--count", type=int, default=10)

    sub.add_parser("load-boot", help="Load boot config")

    args = parser.parse_args()
    mgr = ConfigManager()

    if args.command == "edit":
        mgr.edit_start()
    elif args.command == "show":
        mgr.show_candidate(args.path)
    elif args.command == "compare":
        mgr.compare()
    elif args.command == "set":
        mgr.set_value(args.path, args.value)
    elif args.command == "delete":
        mgr.delete_value(args.path)
    elif args.command == "commit":
        mgr.commit(comment=args.comment, confirm_minutes=args.confirm)
    elif args.command == "confirm":
        mgr.confirm()
    elif args.command == "save":
        mgr.save()
    elif args.command == "discard":
        mgr.discard()
    elif args.command == "rollback":
        mgr.rollback(args.revision)
    elif args.command == "history":
        mgr.history(args.count)
    elif args.command == "load-boot":
        boot = mgr._read_json(BOOT_CONFIG)
        mgr._apply(boot)
        mgr._write_json(ACTIVE_CONFIG, boot)
        print("Boot config loaded.")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
