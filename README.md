# Palette EC backup automation

`palette-ec-backup.sh` automates the source-cluster command-line workflow from
**Palette EC Backup procedure, version 1.1 (July 16, 2026)** and incorporates
the behavior of the supplied `backup-and-restore-scs-4743.tar.gz` utility.

The supplied archive was verified against the procedure:

```text
MD5: b49e10cfe4d204e06883fed6021102e2
```

## What remains manual

Before running a backup, enable:

**Tenant Settings → Platform Settings → Pause Agent Upgrade**

The PDF does not provide an API for this tenant-level UI action. The script
therefore requires `--agent-upgrade-paused` as an explicit operator
confirmation. Remember to follow your change procedure for restoring that
setting after the backup window.

## Requirements

- Bash 3.2 or newer
- `kubectl` with access to the source cluster
- MongoDB Database Tools (`mongodump`) installed on the jump host
- `python3`, `base64`, `awk`, `find`, `sort`, `du`
- `sha256sum` (Ubuntu) or `shasum` (macOS)
- Permission to read secrets and pods, exec into MongoDB pods, and port-forward
  pods in `hubble-system`

The procedure targets an Ubuntu 24.04 jump host and shows how to install
Kubernetes `kubectl` v1.29. This script does not run `apt upgrade` or install
packages automatically. MongoDB Database Tools are distributed separately from
MongoDB Server; the Palette MongoDB container does not include `mongodump`.
Install a Database Tools release compatible with MongoDB 8.0 on the jump host
before running the script. `skopeo` is listed in the PDF prerequisites but is
not used by this backup workflow.

## Run

First inspect the resolved plan without connecting to the cluster:

```bash
./palette-ec-backup.sh \
  --kubeconfig ./source.kubeconfig \
  --backup-dir ./source-backup \
  --dry-run
```

Then run the backup after pausing agent upgrades:

```bash
./palette-ec-backup.sh \
  --kubeconfig ./source.kubeconfig \
  --backup-dir ./source-backup \
  --agent-upgrade-paused
```

The output directory must not already exist. This prevents old and new backup
files from being mixed.

The script opens a temporary loopback port-forward to the discovered primary,
copies the mounted MongoDB TLS client files into a restrictive temporary
directory, and runs the jump host's `mongodump` through that tunnel. It closes
the tunnel and removes the temporary TLS files on success or failure. Set
`MONGO_LOCAL_PORT` if the environment requires a specific loopback port;
otherwise, the script selects an available port. Collection reads are serialized
to avoid concurrent TLS handshakes overwhelming the Kubernetes port-forward. If
the dump fails, `port-forward.log` is retained in the incomplete backup
directory for diagnosis.

## Output

A completed backup contains:

```text
source-backup/
├── COMPLETED
├── SHA256SUMS
├── backup_summary.txt
├── cleaned-secrets/
│   ├── configserversecret.yaml
│   └── msgbroker-secret.yaml
├── hubbledb/
├── hubble_archivedb/
└── hubble_timeseriesdb/
```

The script uses `umask 077`, does not print the database password, and sanitizes
cluster-generated Secret metadata. A failed run retains its local directory
with an `INCOMPLETE` marker.

Verify all files from the parent directory:

```bash
cd source-backup
sha256sum --check SHA256SUMS
```

The backup contains Kubernetes secrets and MongoDB data. Store and transfer it
using controls appropriate for production credentials and customer data.
