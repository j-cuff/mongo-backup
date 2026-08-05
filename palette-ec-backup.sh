#!/usr/bin/env bash
# Compiled by Jason Cuff - Spectrocloud
# Automates the command-line portion of "Palette EC Backup procedure", v1.1.
# The tenant-wide "Pause Agent Upgrade" setting is a UI operation and must be
# confirmed explicitly with --agent-upgrade-paused.

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PREREQUISITE_INSTALLER="${SCRIPT_DIR}/install-prerequisites.sh"
readonly -a DATABASES=(hubbledb hubble_timeseriesdb hubble_archivedb)

KUBECONFIG_FILE=""
BACKUP_DIR=""
NAMESPACE="${NAMESPACE:-hubble-system}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-root}"
AUTH_DB="${AUTH_DB:-admin}"
MONGO_SECRET="${MONGO_SECRET:-spectromongosecret}"
MONGO_QUERY_POD="${MONGO_QUERY_POD:-mongo-0}"
MONGO_LOCAL_PORT="${MONGO_LOCAL_PORT:-}"
AGENT_UPGRADE_PAUSED=false
DRY_RUN=false
REMOTE_POD=""
TLS_TEMP_DIR=""
PORT_FORWARD_PID=""
LOCAL_MONGO_PORT=""
MONGODUMP_TLS_STYLE=""
MONGODUMP_VERSION=""

if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly BLUE=$'\033[0;34m'
    readonly NC=$'\033[0m'
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly NC=""
fi

log_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$GREEN" "$NC" "$*"; }
log_warning() { printf '%s[WARNING]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }

usage() {
    cat <<EOF
Palette EC MongoDB backup

Usage:
  $SCRIPT_NAME --kubeconfig FILE --agent-upgrade-paused [OPTIONS]

Required:
  --kubeconfig FILE          Source cluster kubeconfig
  --agent-upgrade-paused     Confirm that Tenant Settings > Platform Settings >
                             Pause Agent Upgrade is enabled

Options:
  --backup-dir DIR           Output directory
                             (default: ./source-backup-YYYYmmdd-HHMMSS)
  --namespace NAME           Palette namespace (default: hubble-system)
  --dry-run                  Validate local arguments and print the workflow only
  -h, --help                 Show this help

Environment overrides:
  NAMESPACE, MONGO_PORT, MONGO_USER, AUTH_DB, MONGO_SECRET, MONGO_QUERY_POD,
  MONGO_LOCAL_PORT

The output directory is created with restrictive permissions. If a run fails,
the partial output is retained with an INCOMPLETE marker for diagnosis.
EOF
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "$option requires a value"
        exit 2
    fi
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --kubeconfig)
                require_value "$1" "${2:-}"
                KUBECONFIG_FILE="$2"
                shift 2
                ;;
            --backup-dir)
                require_value "$1" "${2:-}"
                BACKUP_DIR="$2"
                shift 2
                ;;
            --namespace)
                require_value "$1" "${2:-}"
                NAMESPACE="$2"
                shift 2
                ;;
            --agent-upgrade-paused)
                AGENT_UPGRADE_PAUSED=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit 2
                ;;
        esac
    done
}

validate_local_inputs() {
    if [[ -z "$KUBECONFIG_FILE" ]]; then
        log_error "--kubeconfig is required"
        exit 2
    fi
    if [[ ! -f "$KUBECONFIG_FILE" ]]; then
        log_error "Kubeconfig not found: $KUBECONFIG_FILE"
        exit 2
    fi
    if [[ ! -r "$KUBECONFIG_FILE" ]]; then
        log_error "Kubeconfig is not readable: $KUBECONFIG_FILE"
        exit 2
    fi
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="./source-backup-$(date +%Y%m%d-%H%M%S)"
    fi
    if [[ "$BACKUP_DIR" == "/" ]]; then
        log_error "Refusing to use / as the backup directory"
        exit 2
    fi
    if [[ -e "$BACKUP_DIR" ]]; then
        log_error "Backup path already exists; choose a new directory: $BACKUP_DIR"
        exit 2
    fi
    if ((${#NAMESPACE} > 63)) ||
        [[ ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        log_error "Invalid Kubernetes namespace: $NAMESPACE"
        exit 2
    fi
    if [[ ! "$MONGO_PORT" =~ ^[0-9]+$ ]]; then
        log_error "Invalid MONGO_PORT: $MONGO_PORT"
        exit 2
    fi
    if ((10#$MONGO_PORT < 1 || 10#$MONGO_PORT > 65535)); then
        log_error "Invalid MONGO_PORT: $MONGO_PORT"
        exit 2
    fi
    if [[ -n "$MONGO_LOCAL_PORT" ]]; then
        if [[ ! "$MONGO_LOCAL_PORT" =~ ^[0-9]+$ ]] ||
            ((10#$MONGO_LOCAL_PORT < 1 || 10#$MONGO_LOCAL_PORT > 65535)); then
            log_error "Invalid MONGO_LOCAL_PORT: $MONGO_LOCAL_PORT"
            exit 2
        fi
    fi
    if [[ "$AGENT_UPGRADE_PAUSED" != true && "$DRY_RUN" != true ]]; then
        log_error "Pause Agent Upgrade must be enabled in Palette before backup."
        log_error "After enabling it, rerun with --agent-upgrade-paused."
        exit 2
    fi
}

print_plan() {
    cat <<EOF
Palette EC backup plan
  Kubeconfig: $KUBECONFIG_FILE
  Namespace:  $NAMESPACE
  Output:     $BACKUP_DIR

  1. Verify kubectl and source-cluster connectivity.
  2. Export sanitized configserversecret and msgbroker-secret manifests.
  3. Read mongoRootPassword from $MONGO_SECRET without printing it.
  4. Discover the current mongo-N primary.
  5. Open a temporary local port-forward to the primary.
  6. Run local mongodump over TLS and retain the three Palette databases.
  7. Close the port-forward and remove temporary TLS files.
  8. Write a summary and SHA-256 manifest.
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command not found: $1"
        if [[ "$1" == "mongodump" ]]; then
            log_error "Install the bundled MongoDB tools with: sudo ./install-prerequisites.sh"
        elif [[ "$1" == "kubectl" ]]; then
            log_error "Install a kubectl version compatible with the target cluster"
        fi
        return 1
    fi
}

detect_prerequisite_install_target() {
    local os_id=""
    local os_version=""

    [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] ||
        return 1
    [[ -r /etc/os-release ]] || return 1

    os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
    os_version="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"

    case "${os_id}:${os_version}" in
        ubuntu:24.04)
            printf '%s' "Ubuntu 24.04 x86-64"
            ;;
        rocky:9.7)
            printf '%s' "Rocky Linux 9.7 x86-64"
            ;;
        *)
            return 1
            ;;
    esac
}

collect_missing_installable_commands() {
    local command_name
    local missing_output=""

    for command_name in mongodump base64 awk find grep sed sort du python3; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            missing_output+="${missing_output:+$'\n'}${command_name}"
        fi
    done
    if ! command -v sha256sum >/dev/null 2>&1 &&
        ! command -v shasum >/dev/null 2>&1; then
        missing_output+="${missing_output:+$'\n'}sha256sum"
    fi

    printf '%s' "${missing_output}"
}

ensure_local_prerequisites() {
    local answer=""
    local command_name
    local detected_target=""
    local missing_output=""
    local -a missing=()

    missing_output="$(collect_missing_installable_commands)"
    if [[ -z "${missing_output}" ]]; then
        return 0
    fi

    while IFS= read -r command_name; do
        [[ -n "${command_name}" ]] && missing+=("${command_name}")
    done <<<"${missing_output}"

    log_warning "Missing local backup prerequisites: ${missing[*]}"
    if ! command -v kubectl >/dev/null 2>&1; then
        log_warning "kubectl is also missing and is not included in the bundle. Install a cluster-compatible kubectl before the backup can continue."
    fi
    if ! detected_target="$(detect_prerequisite_install_target)"; then
        log_error "Automatic prerequisite installation supports only Ubuntu 24.04 and Rocky Linux 9.7 x86-64."
        log_error "Install the missing commands manually, then rerun ${SCRIPT_NAME}."
        return 1
    fi

    log_info "Detected installation target: ${detected_target}"
    if [[ ! -x "${PREREQUISITE_INSTALLER}" ]]; then
        log_error "Prerequisite installer is missing or not executable: ${PREREQUISITE_INSTALLER}"
        return 1
    fi

    printf 'Install the bundled MongoDB tools and required OS packages now? [y/N]: ' >&2
    if ! read -r answer; then
        answer=""
    fi
    case "${answer}" in
        y|Y|yes|YES)
            "${PREREQUISITE_INSTALLER}"
            ;;
        *)
            log_error "Prerequisite installation declined. No packages were changed."
            return 1
            ;;
    esac

    missing_output="$(collect_missing_installable_commands)"
    if [[ -n "${missing_output}" ]]; then
        log_error "Prerequisites are still missing after installation: $(printf '%s' "${missing_output}" | tr '\n' ' ')"
        return 1
    fi

    log_success "Local backup prerequisites are ready."
}

decode_base64() {
    if base64 --help 2>&1 | grep -q -- '--decode'; then
        base64 --decode
    else
        base64 -D
    fi
}

kubectl_cmd() {
    kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"
}

detect_mongodump_tls_options() {
    local help_output
    local version_output

    help_output="$(mongodump --help 2>&1 || true)"
    version_output="$(mongodump --version 2>&1 || true)"
    MONGODUMP_VERSION="${version_output%%$'\n'*}"

    if grep -q -- '--tlsCAFile' <<<"$help_output" &&
        grep -q -- '--tlsAllowInvalidCertificates' <<<"$help_output"; then
        MONGODUMP_TLS_STYLE="tls"
    elif grep -q -- '--tlsCAFile' <<<"$help_output"; then
        log_error "Installed mongodump does not support required option --tlsAllowInvalidCertificates"
        log_error "Detected: ${MONGODUMP_VERSION:-unknown mongodump version}"
        return 1
    elif grep -q -- '--sslCAFile' <<<"$help_output"; then
        MONGODUMP_TLS_STYLE="ssl"
    else
        log_error "Installed mongodump does not expose supported TLS/SSL options"
        log_error "Install a MongoDB Database Tools release compatible with MongoDB 8.0"
        return 1
    fi

    log_info "Using ${MONGODUMP_VERSION:-mongodump} with $MONGODUMP_TLS_STYLE options"
}

preflight_cluster() {
    local command_name
    for command_name in kubectl mongodump base64 awk find grep sed sort du python3; do
        require_command "$command_name"
    done
    if ! command -v sha256sum >/dev/null 2>&1 &&
        ! command -v shasum >/dev/null 2>&1; then
        log_error "Required checksum command not found: install sha256sum or shasum"
        return 1
    fi
    detect_mongodump_tls_options

    log_info "Checking access to the source cluster..."
    kubectl_cmd cluster-info >/dev/null

    local context
    context="$(kubectl_cmd config current-context 2>/dev/null || true)"
    log_info "Connected with context: ${context:-unknown}"

    for secret in configserversecret msgbroker-secret "$MONGO_SECRET"; do
        if ! kubectl_cmd get secret "$secret" -n "$NAMESPACE" >/dev/null; then
            log_error "Required secret not found: $NAMESPACE/$secret"
            return 1
        fi
    done

    local pods
    pods="$(kubectl_cmd get pods -n "$NAMESPACE" -o name | sed -n 's#^pod/\(mongo-[0-9][0-9]*\)$#\1#p')"
    if [[ -z "$pods" ]]; then
        log_error "No mongo-N pods found in namespace $NAMESPACE"
        return 1
    fi
    if ! grep -qx "$MONGO_QUERY_POD" <<<"$pods"; then
        log_error "MongoDB query pod not found: $NAMESPACE/$MONGO_QUERY_POD"
        return 1
    fi
}

create_output_directory() {
    umask 077
    mkdir -p "$BACKUP_DIR/cleaned-secrets"
    printf 'Backup did not complete. Review the command output before reusing any files.\n' \
        >"$BACKUP_DIR/INCOMPLETE"
}

# Rebuild the Secret manifest from only restore-relevant fields. This avoids
# persisting cluster-generated metadata or last-applied annotations.
export_clean_secret() {
    local secret_name="$1"
    local output_file="$BACKUP_DIR/cleaned-secrets/${secret_name}.yaml"
    local raw_file="$BACKUP_DIR/cleaned-secrets/.${secret_name}.raw.yaml"

    log_info "Exporting $NAMESPACE/$secret_name..."
    kubectl_cmd get secret "$secret_name" -n "$NAMESPACE" \
        -o yaml --show-managed-fields=false >"$raw_file"

    awk -v secret_name="$secret_name" -v namespace="$NAMESPACE" '
        BEGIN {
            print "apiVersion: v1"
            print "kind: Secret"
            print "metadata:"
            print "  name: " secret_name
            print "  namespace: " namespace
        }
        /^data:$/ {
            in_data = 1
            saw_data = 1
            print
            next
        }
        in_data && /^  / {
            print
            next
        }
        in_data {
            in_data = 0
        }
        /^immutable:/ {
            print
        }
        /^type:/ {
            print
            saw_type = 1
        }
        END {
            if (!saw_data || !saw_type) {
                exit 3
            }
        }
    ' "$raw_file" >"$output_file"

    rm -f "$raw_file"
    chmod 600 "$output_file"
}

read_mongo_root_password() {
    local encoded_password
    encoded_password="$(kubectl_cmd get secret "$MONGO_SECRET" -n "$NAMESPACE" \
        -o 'jsonpath={.data.mongoRootPassword}')"
    if [[ -z "$encoded_password" ]]; then
        log_error "mongoRootPassword is missing from $NAMESPACE/$MONGO_SECRET"
        return 1
    fi

    local password
    if ! password="$(printf '%s' "$encoded_password" | decode_base64)"; then
        log_error "Could not decode mongoRootPassword"
        return 1
    fi
    if [[ -z "$password" ]]; then
        log_error "Decoded mongoRootPassword is empty"
        return 1
    fi
    printf '%s' "$password"
}

mongo_primary_from_status() {
    python3 -c 'import json, re, sys
status = sys.stdin.read()

try:
    members = json.loads(status)
    primary = next((
        member.get("name", "")
        for member in members
        if member.get("state") == "PRIMARY" and member.get("health") == 1
    ), "")
except (json.JSONDecodeError, TypeError):
    primary = ""
    for member in re.findall(r"\{(.*?)\}", status, re.DOTALL):
        state = re.search(r"""(?:^|,)\s*state\s*:\s*([\"'\''])PRIMARY\1""", member)
        health = re.search(r"(?:^|,)\s*health\s*:\s*1(?:\s*,|\s*$)", member)
        name = re.search(r"""(?:^|,)\s*name\s*:\s*([\"'\''])(.*?)\1""", member)
        if state and health and name:
            primary = name.group(2)
            break

print(primary.split(":", 1)[0].split(".", 1)[0])'
}

discover_primary() {
    local password="$1"
    local primary
    local result

    log_info "Querying MongoDB replica-set status from $MONGO_QUERY_POD..." >&2
    if ! result="$(
        kubectl_cmd exec -n "$NAMESPACE" "$MONGO_QUERY_POD" -c mongo -- \
            env OPENSSL_CONF=/dev/null mongosh \
            --port "$MONGO_PORT" \
            -u "$MONGO_USER" \
            -p "$password" \
            --authenticationDatabase "$AUTH_DB" \
            --tls \
            --tlsCAFile /var/mongodb/tls/ca.crt \
            --tlsCertificateKeyFile /var/mongodb/tls/tls-combined.pem \
            --tlsAllowInvalidCertificates \
            --quiet \
            --eval "rs.status().members.map(m => ({name: m.name, state: m.stateStr, health: m.health, optime: m.optimeDate}))"
    )"; then
        log_error "Authenticated TLS replica-set status query failed"
        return 1
    fi

    result="${result//$'\r'/}"
    log_info "MongoDB replica-set members:" >&2
    printf '%s\n' "$result" >&2
    primary="$(printf '%s' "$result" | mongo_primary_from_status)"
    if [[ -z "$primary" ]]; then
        log_error "No healthy MongoDB primary found"
        return 1
    fi

    printf '%s' "$primary"
}

cleanup_local_transport() {
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        log_info "Closing MongoDB port-forward..."
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
        wait "$PORT_FORWARD_PID" 2>/dev/null || true
        PORT_FORWARD_PID=""
    fi

    if [[ -n "$TLS_TEMP_DIR" && -d "$TLS_TEMP_DIR" ]]; then
        rm -f -- \
            "$TLS_TEMP_DIR/ca.crt" \
            "$TLS_TEMP_DIR/tls-combined.pem" \
            "$TLS_TEMP_DIR/port-forward.log"
        rmdir "$TLS_TEMP_DIR" 2>/dev/null || true
        TLS_TEMP_DIR=""
    fi
}

on_exit() {
    local status=$?

    if ((status != 0)) &&
        [[ -n "$TLS_TEMP_DIR" && -f "$TLS_TEMP_DIR/port-forward.log" &&
        -d "$BACKUP_DIR" ]]; then
        sed -n 'p' "$TLS_TEMP_DIR/port-forward.log" \
            >"$BACKUP_DIR/port-forward.log"
        chmod 600 "$BACKUP_DIR/port-forward.log"
        log_info "Saved port-forward diagnostics: $BACKUP_DIR/port-forward.log"
    fi

    cleanup_local_transport

    if ((status != 0)); then
        log_error "Backup failed. Partial output, if any, remains at: $BACKUP_DIR"
    fi
    return "$status"
}

select_local_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

copy_mongo_tls_file() {
    local remote_file="$1"
    local local_file="$2"

    if ! kubectl_cmd exec -n "$NAMESPACE" "$REMOTE_POD" -c mongo -- \
        cat "$remote_file" >"$local_file"; then
        rm -f -- "$local_file"
        log_error "Could not read MongoDB TLS file: $remote_file"
        return 1
    fi
    if [[ ! -s "$local_file" ]]; then
        rm -f -- "$local_file"
        log_error "MongoDB TLS file is empty: $remote_file"
        return 1
    fi
    chmod 600 "$local_file"
}

prepare_local_transport() {
    local temp_root="${TMPDIR:-/tmp}"
    local attempt

    TLS_TEMP_DIR="$(mktemp -d "${temp_root%/}/palette-ec-mongo-tls.XXXXXX")"
    chmod 700 "$TLS_TEMP_DIR"

    log_info "Copying temporary MongoDB TLS files from $REMOTE_POD..."
    copy_mongo_tls_file \
        /var/mongodb/tls/ca.crt \
        "$TLS_TEMP_DIR/ca.crt"
    copy_mongo_tls_file \
        /var/mongodb/tls/tls-combined.pem \
        "$TLS_TEMP_DIR/tls-combined.pem"

    if [[ -n "$MONGO_LOCAL_PORT" ]]; then
        LOCAL_MONGO_PORT="$MONGO_LOCAL_PORT"
    else
        LOCAL_MONGO_PORT="$(select_local_port)"
    fi
    log_info "Opening port-forward to $REMOTE_POD on 127.0.0.1:$LOCAL_MONGO_PORT..."
    kubectl_cmd port-forward -n "$NAMESPACE" --address 127.0.0.1 \
        "pod/$REMOTE_POD" "$LOCAL_MONGO_PORT:$MONGO_PORT" \
        >"$TLS_TEMP_DIR/port-forward.log" 2>&1 &
    PORT_FORWARD_PID=$!

    for attempt in {1..50}; do
        if grep -q "Forwarding from 127.0.0.1:$LOCAL_MONGO_PORT" \
            "$TLS_TEMP_DIR/port-forward.log"; then
            return 0
        fi
        if ! kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    log_error "Could not establish the MongoDB port-forward"
    sed 's/^/  /' "$TLS_TEMP_DIR/port-forward.log" >&2
    return 1
}

dump_databases_locally() {
    local password="$1"
    local database
    local dump_status
    local raw_dump_dir="$BACKUP_DIR/.mongo-dump"
    local -a tls_options

    if [[ "$MONGODUMP_TLS_STYLE" == "tls" ]]; then
        tls_options=(
            --tls
            --tlsCAFile "$TLS_TEMP_DIR/ca.crt"
            --tlsCertificateKeyFile "$TLS_TEMP_DIR/tls-combined.pem"
            --tlsAllowInvalidCertificates
        )
    else
        tls_options=(
            --ssl
            --sslCAFile "$TLS_TEMP_DIR/ca.crt"
            --sslPEMKeyFile "$TLS_TEMP_DIR/tls-combined.pem"
            --sslAllowInvalidHostnames
        )
    fi

    log_info "Running local mongodump through the TLS port-forward..."
    if OPENSSL_CONF=/dev/null mongodump \
        --host 127.0.0.1 \
        --port "$LOCAL_MONGO_PORT" \
        -u "$MONGO_USER" \
        -p "$password" \
        --authenticationDatabase "$AUTH_DB" \
        "${tls_options[@]}" \
        --numParallelCollections=1 \
        --gzip \
        --out="$raw_dump_dir"; then
        dump_status=0
    else
        dump_status=$?
    fi

    if ((dump_status != 0)); then
        if [[ -n "$PORT_FORWARD_PID" ]] &&
            ! kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
            log_error "mongodump failed after the port-forward process exited"
            sed 's/^/  /' "$TLS_TEMP_DIR/port-forward.log" >&2
        else
            log_error "mongodump failed while the port-forward remained active"
        fi
        return "$dump_status"
    fi

    for database in "${DATABASES[@]}"; do
        log_info "Verifying dump for $database..."
        if [[ ! -d "$raw_dump_dir/$database" ]]; then
            log_error "mongodump did not create $database"
            return 1
        fi
        if ! find "$raw_dump_dir/$database" -type f -print -quit | grep -q .; then
            log_error "Dumped database directory is empty: $database"
            return 1
        fi
        mv "$raw_dump_dir/$database" "$BACKUP_DIR/$database"
    done

    rm -rf -- "$raw_dump_dir"
}

human_size() {
    du -sh "$1" 2>/dev/null | awk '{print $1}'
}

write_sha256_manifest() {
    local manifest="$BACKUP_DIR/SHA256SUMS"
    local file

    : >"$manifest"
    while IFS= read -r -d '' file; do
        if command -v sha256sum >/dev/null 2>&1; then
            (
                cd "$BACKUP_DIR"
                sha256sum "${file#"$BACKUP_DIR/"}"
            ) >>"$manifest"
        else
            (
                cd "$BACKUP_DIR"
                shasum -a 256 "${file#"$BACKUP_DIR/"}"
            ) >>"$manifest"
        fi
    done < <(
        find "$BACKUP_DIR" -type f \
            ! -name SHA256SUMS \
            ! -name INCOMPLETE \
            ! -name COMPLETED \
            -print0 | sort -z
    )
    chmod 600 "$manifest"
}

write_summary() {
    local context="$1"
    local database
    local summary="$BACKUP_DIR/backup_summary.txt"

    {
        echo "Palette EC MongoDB Backup Summary"
        echo "================================="
        echo "Procedure version: 1.1"
        echo "Backup date (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Kubernetes context: ${context:-unknown}"
        echo "Namespace: $NAMESPACE"
        echo "MongoDB primary: $REMOTE_POD"
        echo
        echo "Databases:"
        for database in "${DATABASES[@]}"; do
            echo "  - $database: $(human_size "$BACKUP_DIR/$database")"
        done
        echo
        echo "Secrets:"
        echo "  - cleaned-secrets/configserversecret.yaml"
        echo "  - cleaned-secrets/msgbroker-secret.yaml"
        echo
        echo "Integrity manifest: SHA256SUMS"
        echo "Sensitive values are intentionally omitted from this summary."
    } >"$summary"
    chmod 600 "$summary"
}

main() {
    if (($# == 0)); then
        usage
        return 0
    fi

    parse_arguments "$@"
    validate_local_inputs

    if [[ "$DRY_RUN" == true ]]; then
        print_plan
        exit 0
    fi

    ensure_local_prerequisites

    trap on_exit EXIT

    preflight_cluster
    create_output_directory

    local context
    local password
    context="$(kubectl_cmd config current-context 2>/dev/null || true)"

    log_info "Step 1/6: Exporting restore-compatible secrets..."
    export_clean_secret configserversecret
    export_clean_secret msgbroker-secret

    log_info "Step 2/6: Reading MongoDB credentials..."
    password="$(read_mongo_root_password)"

    log_info "Step 3/6: Discovering the MongoDB primary..."
    REMOTE_POD="$(discover_primary "$password")"
    log_success "MongoDB primary: $REMOTE_POD"

    log_info "Step 4/6: Preparing a local TLS connection to MongoDB..."
    prepare_local_transport

    log_info "Step 5/6: Dumping and verifying databases..."
    dump_databases_locally "$password"
    unset password

    cleanup_local_transport

    log_info "Step 6/6: Writing summary and integrity manifest..."
    write_summary "$context"
    write_sha256_manifest
    rm -f -- "$BACKUP_DIR/INCOMPLETE"
    printf 'Backup completed successfully. Verify SHA256SUMS before restore or transfer.\n' \
        >"$BACKUP_DIR/COMPLETED"
    chmod 600 "$BACKUP_DIR/COMPLETED"

    log_success "Backup completed: $BACKUP_DIR"
    log_warning "Keep this directory secure: it contains database data and Kubernetes secrets."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
