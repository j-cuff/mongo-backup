# Bundled backup prerequisites

This directory includes MongoDB Database Tools for the supported x86-64 jump
hosts: **Ubuntu 24.04** and **Rocky Linux 9.7**.

Bundled artifacts:

| Artifact | Version | Upstream source |
| --- | --- | --- |
| MongoDB Database Tools Ubuntu `.deb` | 100.17.0 | `https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2404-x86_64-100.17.0.deb` |
| MongoDB Database Tools RHEL 9 `.rpm` for Rocky Linux | 100.17.0 | `https://fastdl.mongodb.org/tools/db/mongodb-database-tools-rhel93-x86_64-100.17.0.rpm` |

MongoDB Database Tools contain `mongodump`, `mongorestore`, and the related
MongoDB command-line utilities. MongoDB publishes them under the Apache 2.0
license. The RHEL 9 build is used on the compatible Rocky Linux 9.7 target.

`packages/SHA256SUMS` records both artifact hashes. MongoDB's download page
provides the packages but does not currently link separate checksum files; the
recorded hashes were computed immediately after downloading each package over
HTTPS from the upstream URLs above.

The top-level installer verifies both hashes before making changes. It then uses
the host's configured apt or dnf repositories to install the small OS packages
and shared libraries needed by the backup workflow and the selected MongoDB
package. MongoDB Database Tools do not need to be downloaded on the jump host.
kubectl is deliberately not bundled or installed; provide a kubectl release
within the supported version skew of the target Kubernetes cluster.

Verify the bundle on any host with `sha256sum` or `shasum`:

```bash
./install-prerequisites.sh --verify-only
```

Install on the supported jump host:

```bash
sudo ./install-prerequisites.sh
```

On Ubuntu, the installer runs `apt-get update`; on Rocky Linux, it runs
`dnf makecache`. It never runs an OS upgrade or distribution upgrade.
