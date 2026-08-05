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

## Before you run

The supported jump hosts are:

- Ubuntu 24.04 x86-64
- Rocky Linux 9.7 x86-64

You must provide:

- Bash 3.2 or newer
- `kubectl` configured for the source cluster and compatible with its Kubernetes
  version
- A readable kubeconfig
- Permission to read secrets and pods, exec into MongoDB pods, and port-forward
  pods in `hubble-system`
- Access to the host's configured apt or dnf repositories if prerequisites must
  be installed

Kubectl is intentionally not bundled, installed, or replaced. `skopeo` is
listed in the source PDF prerequisites but is not used by this workflow.

## Run the backup

First inspect the resolved plan without connecting to the cluster:

Running the script without arguments displays its usage and exits without
starting a backup.

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

That is the only script you normally need to execute. Before contacting the
cluster, `palette-ec-backup.sh` checks for MongoDB Database Tools and the local
commands used by the backup. If anything installable is missing, it detects the
operating system and displays a confirmation prompt such as:

```text
[WARNING] Missing local backup prerequisites: mongodump
[INFO] Detected installation target: Rocky Linux 9.7 x86-64
Install the bundled MongoDB tools and required OS packages now? [y/N]:
```

Answering `y` runs the bundled installer. It may request sudo access, verifies
the bundled package checksums, refreshes apt or dnf metadata, installs the
required OS packages, and installs MongoDB Database Tools 100.17.0. It never
runs an operating-system upgrade. After installation, the backup script verifies
the commands again and continues automatically.

Answering anything else stops the backup without changing packages. `--dry-run`
never prompts or installs software. If kubectl is missing, the script reports it
separately because kubectl is not part of the bundle.

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

## Prerequisite bundle

The repository includes MongoDB Database Tools 100.17.0 packages for both
supported operating systems:

- Ubuntu package: `mongodb-database-tools-ubuntu2404-x86_64-100.17.0.deb`
- Rocky-compatible RHEL 9 package:
  `mongodb-database-tools-rhel93-x86_64-100.17.0.rpm`

To verify both bundled artifacts without installing anything:

```bash
./install-prerequisites.sh --verify-only
```

You can also invoke the installer directly for host preparation or
troubleshooting:

```bash
sudo ./install-prerequisites.sh
```

See [`prerequisites/README.md`](prerequisites/README.md) for upstream URLs,
hashes, package provenance, and platform constraints.

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
