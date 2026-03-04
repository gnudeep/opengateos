# GitOps Workflow for OpenGateOS

Manage your gateway configuration in Git and apply changes to the running system with a simple pull-and-apply workflow.

## Repo Structure

```
opengateos/
├── configs/
│   ├── harvester-gateway.json    # Production gateway config
│   └── lab-gateway.json          # Lab/test environment (optional)
├── scripts/
│   └── apply-config.sh           # Pull + apply script
└── docs/
    ├── harvester-gateway-setup.md
    └── gitops-workflow.md
```

Each environment gets its own config file under `configs/`. The gateway VM pulls and applies the file relevant to it.

## Workflow

### 1. Edit config locally

```bash
# Clone the repo (if you haven't already)
git clone git@your-server:opengateos.git
cd opengateos

# Edit the config
vi configs/harvester-gateway.json

# Validate JSON
python3 -c "import json; json.load(open('configs/harvester-gateway.json'))"
```

### 2. Commit and push

```bash
git add configs/harvester-gateway.json
git commit -m "Add DHCP reservation for k8s-node-01"
git push
```

### 3. Apply on the gateway

SSH into the gateway VM and run:

```bash
/opt/opengateos/scripts/apply-config.sh
```

The script will:
1. Pull the latest changes from the repo
2. Skip if already up to date
3. Validate the JSON config
4. Copy it to `/config/candidate/config.json`
5. Show a diff via `routercli compare`
6. Commit and save via `routercli commit` and `routercli save`

### First-time setup on the gateway

```bash
# Set the repo URL and clone
export REPO_URL="git@your-server:opengateos.git"
export REPO_DIR="/opt/opengateos"
/opt/opengateos/scripts/apply-config.sh
```

Or clone manually first:

```bash
git clone git@your-server:opengateos.git /opt/opengateos
/opt/opengateos/scripts/apply-config.sh
```

## Rollback

If a config change causes problems, use routercli's built-in rollback:

```bash
# View config history
routercli history

# Rollback to a previous revision
routercli rollback 1
routercli save
```

Or revert the commit in Git and re-apply:

```bash
# On your workstation
git revert HEAD
git push

# On the gateway
/opt/opengateos/scripts/apply-config.sh
```

## Safe Deployments with Commit-Confirm

For risky changes, use routercli's commit-confirm feature. Instead of running the apply script, do it manually:

```bash
cd /opt/opengateos && git pull
cp configs/harvester-gateway.json /config/candidate/config.json
routercli compare
routercli commit --confirm 5    # Auto-rollback in 5 minutes if not confirmed
```

Test connectivity, then confirm:

```bash
routercli confirm
routercli save
```

If you lose access, the config automatically rolls back after 5 minutes.

## Optional: Automated Apply with systemd Timer

Create a systemd timer to periodically pull and apply config changes.

### `/etc/systemd/system/gitops-apply.service`

```ini
[Unit]
Description=GitOps config apply for OpenGateOS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/opengateos/scripts/apply-config.sh
Environment=REPO_DIR=/opt/opengateos
StandardOutput=journal
StandardError=journal
```

### `/etc/systemd/system/gitops-apply.timer`

```ini
[Unit]
Description=Run GitOps apply every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
```

### Enable the timer

```bash
systemctl daemon-reload
systemctl enable --now gitops-apply.timer

# Check status
systemctl list-timers gitops-apply.timer
journalctl -u gitops-apply.service -f
```

> **Note:** The automated timer is optional. The default workflow is to SSH in and run the apply script manually after pushing config changes.
