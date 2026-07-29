#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/palette-ec-backup-test.XXXXXX")"
MOCK_BIN="$TEST_DIR/bin"
LOG_FILE="$TEST_DIR/kubectl.log"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN"
touch "$TEST_DIR/source.kubeconfig"

cat >"$MOCK_BIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"$MOCK_KUBECTL_LOG"
printf '\n' >>"$MOCK_KUBECTL_LOG"

if [[ "${1:-}" == "--kubeconfig" ]]; then
    shift 2
fi

case "${1:-}" in
    cluster-info)
        exit 0
        ;;
    config)
        echo "mock-source-context"
        ;;
    get)
        resource="${2:-}"
        name="${3:-}"
        if [[ "$resource" == "secret" && "$*" == *"jsonpath={.data.mongoRootPassword}"* ]]; then
            printf 'bW9jay1wYXNzd29yZA=='
        elif [[ "$resource" == "secret" && "$*" == *"-o yaml"* ]]; then
            cat <<EOF
apiVersion: v1
data:
  dbPassword: bW9jay1wYXNzd29yZA==
  sample: dmFsdWU=
kind: Secret
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: ignored
  creationTimestamp: "2026-07-23T00:00:00Z"
  name: $name
  namespace: hubble-system
  resourceVersion: "123"
  uid: ignored
type: Opaque
EOF
        elif [[ "$resource" == "secret" ]]; then
            exit 0
        elif [[ "$resource" == "pods" ]]; then
            printf 'pod/mongo-0\npod/mongo-1\npod/not-mongo\n'
        fi
        ;;
    -n|exec)
        if [[ "${1:-}" == "-n" ]]; then
            shift 2
        fi
        if [[ "${1:-}" == "exec" ]]; then
            shift
            if [[ "${1:-}" == "-n" ]]; then
                shift 2
            fi
            pod="${1:-}"
            while (($# > 0)) && [[ "$1" != "--" ]]; do
                shift
            done
            shift
            if [[ "${1:-}" == "env" ]]; then
                shift 2
            fi
            if [[ "${1:-}" == "mongosh" ]]; then
                cat <<EOF
[
  { name: 'mongo-0.mongo:27017', state: 'SECONDARY', health: 1, optime: ISODate('2026-07-23T00:00:00Z') },
  { name: 'mongo-1.mongo:27017', state: 'PRIMARY', health: 1, optime: ISODate('2026-07-23T00:00:01Z') }
]
EOF
            elif [[ "${1:-}" == "cat" ]]; then
                printf '%s\n' 'mock TLS data'
            else
                exit 0
            fi
        fi
        ;;
    port-forward)
        mapping="${!#}"
        local_port="${mapping%%:*}"
        printf 'Forwarding from 127.0.0.1:%s -> 27017\n' "$local_port"
        trap 'exit 0' TERM INT
        while true; do
            sleep 1
        done
        ;;
    *)
        echo "Unexpected mock kubectl invocation: $*" >&2
        exit 9
        ;;
esac
MOCK
chmod +x "$MOCK_BIN/kubectl"

cat >"$MOCK_BIN/mongodump" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf 'mongodump ' >>"$MOCK_KUBECTL_LOG"
printf '%q ' "$@" >>"$MOCK_KUBECTL_LOG"
printf '\n' >>"$MOCK_KUBECTL_LOG"

if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' \
        '  --ssl' \
        '  --sslCAFile=<filename>' \
        '  --sslPEMKeyFile=<filename>' \
        '  --sslAllowInvalidHostnames'
    exit 0
fi
if [[ "${1:-}" == "--version" ]]; then
    printf '%s\n' 'mongodump version: 100.17.0'
    exit 0
fi

if [[ "${MOCK_FAIL_DUMP:-}" == "true" ]]; then
    exit 17
fi

output_dir=""
for argument in "$@"; do
    if [[ "$argument" == --out=* ]]; then
        output_dir="${argument#--out=}"
    fi
done
[[ -n "$output_dir" ]]

for database in hubbledb hubble_timeseriesdb hubble_archivedb admin; do
    mkdir -p "$output_dir/$database"
    printf 'mock dump\n' >"$output_dir/$database/collection.bson.gz"
done
MOCK
chmod +x "$MOCK_BIN/mongodump"

export PATH="$MOCK_BIN:$PATH"
export MOCK_KUBECTL_LOG="$LOG_FILE"
export MONGO_LOCAL_PORT=37017

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

assert_contains() {
    grep -q -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_not_contains() {
    if grep -q -- "$2" "$1"; then
        fail "$1 unexpectedly contains: $2"
    fi
}

DRY_RUN_OUTPUT="$TEST_DIR/dry-run.txt"
"$PROJECT_DIR/palette-ec-backup.sh" \
    --kubeconfig "$TEST_DIR/source.kubeconfig" \
    --backup-dir "$TEST_DIR/dry-run-output" \
    --dry-run >"$DRY_RUN_OUTPUT"
assert_contains "$DRY_RUN_OUTPUT" "Palette EC backup plan"
[[ ! -e "$TEST_DIR/dry-run-output" ]] || fail "dry-run created output"

if "$PROJECT_DIR/palette-ec-backup.sh" \
    --kubeconfig "$TEST_DIR/source.kubeconfig" \
    --backup-dir "$TEST_DIR/no-confirmation" >/dev/null 2>&1; then
    fail "backup ran without --agent-upgrade-paused"
fi

BACKUP_DIR="$TEST_DIR/source-backup"
"$PROJECT_DIR/palette-ec-backup.sh" \
    --kubeconfig "$TEST_DIR/source.kubeconfig" \
    --backup-dir "$BACKUP_DIR" \
    --agent-upgrade-paused

assert_file "$BACKUP_DIR/COMPLETED"
assert_file "$BACKUP_DIR/SHA256SUMS"
assert_file "$BACKUP_DIR/backup_summary.txt"
assert_file "$BACKUP_DIR/cleaned-secrets/configserversecret.yaml"
assert_file "$BACKUP_DIR/cleaned-secrets/msgbroker-secret.yaml"
assert_file "$BACKUP_DIR/hubbledb/collection.bson.gz"
assert_file "$BACKUP_DIR/hubble_timeseriesdb/collection.bson.gz"
assert_file "$BACKUP_DIR/hubble_archivedb/collection.bson.gz"
[[ ! -e "$BACKUP_DIR/INCOMPLETE" ]] || fail "INCOMPLETE remains after success"
assert_contains "$BACKUP_DIR/COMPLETED" "Backup completed successfully"
assert_not_contains "$BACKUP_DIR/COMPLETED" "Backup did not complete"

assert_not_contains "$BACKUP_DIR/cleaned-secrets/configserversecret.yaml" "resourceVersion"
assert_not_contains "$BACKUP_DIR/cleaned-secrets/configserversecret.yaml" "creationTimestamp"
assert_contains "$BACKUP_DIR/cleaned-secrets/configserversecret.yaml" "dbPassword:"
assert_not_contains "$BACKUP_DIR/backup_summary.txt" "mock-password"
assert_contains "$BACKUP_DIR/backup_summary.txt" "MongoDB primary: mongo-1"
assert_not_contains "$BACKUP_DIR/backup_summary.txt" "\\[INFO\\]"
assert_contains "$LOG_FILE" "mongo-1"
assert_contains "$LOG_FILE" "spectromongosecret"
assert_contains "$LOG_FILE" "mongoRootPassword"
assert_contains "$LOG_FILE" "OPENSSL_CONF=/dev/null"
assert_contains "$LOG_FILE" "--tlsCAFile"
assert_contains "$LOG_FILE" "--tlsCertificateKeyFile"
assert_contains "$LOG_FILE" "--tlsAllowInvalidHostnames"
assert_contains "$LOG_FILE" "rs.status"
assert_contains "$LOG_FILE" "port-forward"
assert_contains "$LOG_FILE" "port-forward -n hubble-system"
assert_contains "$LOG_FILE" "mongodump"
assert_contains "$LOG_FILE" "--host 127.0.0.1"
assert_contains "$LOG_FILE" "--ssl"
assert_contains "$LOG_FILE" "--sslCAFile"
assert_contains "$LOG_FILE" "--sslPEMKeyFile"
assert_contains "$LOG_FILE" "--sslAllowInvalidHostnames"
assert_contains "$LOG_FILE" "--numParallelCollections=1"
assert_contains "$LOG_FILE" "/var/mongodb/tls/ca.crt"
assert_contains "$LOG_FILE" "/var/mongodb/tls/tls-combined.pem"

(
    cd "$BACKUP_DIR"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum --check SHA256SUMS >/dev/null
    else
        shasum -a 256 --check SHA256SUMS >/dev/null
    fi
)

FAILURE_BACKUP_DIR="$TEST_DIR/failed-backup"
: >"$LOG_FILE"
export MOCK_FAIL_DUMP=true
if "$PROJECT_DIR/palette-ec-backup.sh" \
    --kubeconfig "$TEST_DIR/source.kubeconfig" \
    --backup-dir "$FAILURE_BACKUP_DIR" \
    --agent-upgrade-paused >/dev/null 2>&1; then
    fail "simulated mongodump failure returned success"
fi
unset MOCK_FAIL_DUMP

assert_file "$FAILURE_BACKUP_DIR/INCOMPLETE"
assert_file "$FAILURE_BACKUP_DIR/port-forward.log"
[[ ! -e "$FAILURE_BACKUP_DIR/COMPLETED" ]] || fail "failed backup has COMPLETED marker"
assert_contains "$FAILURE_BACKUP_DIR/INCOMPLETE" "Backup did not complete"
assert_contains "$FAILURE_BACKUP_DIR/port-forward.log" "Forwarding from 127.0.0.1"
assert_contains "$LOG_FILE" "mongodump"
assert_contains "$LOG_FILE" "port-forward"

echo "PASS: palette-ec-backup workflow"
