#!/usr/bin/env bash
# Installs the local prerequisites for palette-ec-backup.sh on Ubuntu 24.04 or
# Rocky Linux 9.7 x86-64. MongoDB Database Tools packages are bundled beneath
# prerequisites/packages so they do not need to be downloaded on the jump host.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PACKAGE_DIR="${SCRIPT_DIR}/prerequisites/packages"
readonly MONGO_TOOLS_VERSION="100.17.0"
readonly UBUNTU_MONGO_PACKAGE="${PACKAGE_DIR}/mongodb-database-tools-ubuntu2404-x86_64-${MONGO_TOOLS_VERSION}.deb"
readonly ROCKY_MONGO_PACKAGE="${PACKAGE_DIR}/mongodb-database-tools-rhel93-x86_64-${MONGO_TOOLS_VERSION}.rpm"
readonly UBUNTU_MONGO_SHA256="cfc40386b5c909509fd4b35a4a1f212aeaedc17a3062703d4b4b0823c2beb1b7"
readonly ROCKY_MONGO_SHA256="d3c341c123e29d376b36d7245c9eed5ec0ea283d839cedb6017348c27269e78f"

VERIFY_ONLY=false
TARGET_OS=""

usage() {
    cat <<EOF
Install Palette EC backup prerequisites

Usage:
  ${0##*/} [OPTIONS]

Options:
  --verify-only  verify bundled artifacts without changing the host
  -h, --help     show this help

Supported installation targets:
  Ubuntu 24.04 x86-64 (amd64)
  Rocky Linux 9.7 x86-64

kubectl is required by the backup workflow but is not installed by this script.
EOF
}

log() { printf '[INFO] %s\n' "$*"; }
fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --verify-only)
                VERIFY_ONLY=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
    done
}

sha256_of() {
    local file="$1"
    local checksum_output
    if command -v sha256sum >/dev/null 2>&1; then
        checksum_output="$(sha256sum "${file}")"
    elif command -v shasum >/dev/null 2>&1; then
        checksum_output="$(shasum -a 256 "${file}")"
    else
        fail "A SHA-256 utility is required (sha256sum or shasum)"
    fi
    printf '%s\n' "${checksum_output%% *}"
}

verify_artifact() {
    local file="$1"
    local expected="$2"
    local actual

    [[ -f "${file}" ]] || fail "Bundled artifact is missing: ${file}"
    actual="$(sha256_of "${file}")"
    if [[ "${actual}" != "${expected}" ]]; then
        fail "Checksum mismatch for ${file##*/}: expected ${expected}, got ${actual}"
    fi
    log "Verified ${file##*/}"
}

verify_bundle() {
    verify_artifact "${UBUNTU_MONGO_PACKAGE}" "${UBUNTU_MONGO_SHA256}"
    verify_artifact "${ROCKY_MONGO_PACKAGE}" "${ROCKY_MONGO_SHA256}"
}

validate_target() {
    [[ "$(uname -s)" == "Linux" ]] ||
        fail "Installation is supported only on Ubuntu 24.04 or Rocky Linux 9.7 x86-64"
    [[ -r /etc/os-release ]] || fail "Cannot identify the Linux distribution"
    [[ "$(uname -m)" == "x86_64" ]] ||
        fail "Expected x86-64; found $(uname -m)"

    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:24.04)
            TARGET_OS="ubuntu"
            command -v dpkg >/dev/null 2>&1 || fail "dpkg is required on Ubuntu"
            [[ "$(dpkg --print-architecture)" == "amd64" ]] ||
                fail "Expected amd64; found $(dpkg --print-architecture)"
            ;;
        rocky:9.7)
            TARGET_OS="rocky"
            command -v rpm >/dev/null 2>&1 || fail "rpm is required on Rocky Linux"
            [[ "$(rpm --eval '%{_arch}')" == "x86_64" ]] ||
                fail "Expected x86_64; found $(rpm --eval '%{_arch}')"
            ;;
        *)
            fail "Expected Ubuntu 24.04 or Rocky Linux 9.7; found ${PRETTY_NAME:-unknown Linux distribution}"
            ;;
    esac
}

root_command() {
    if ((EUID == 0)); then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 ||
            fail "Run as root or install sudo"
        sudo "$@"
    fi
}

install_ubuntu_packages() {
    command -v apt-get >/dev/null 2>&1 || fail "apt-get is required"

    log "Refreshing Ubuntu package metadata (no distribution upgrade is run)..."
    root_command apt-get update

    log "Installing OS prerequisites and bundled MongoDB Database Tools ${MONGO_TOOLS_VERSION}..."
    root_command env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        findutils \
        grep \
        mawk \
        python3 \
        sed \
        "${UBUNTU_MONGO_PACKAGE}"
}

install_rocky_packages() {
    command -v dnf >/dev/null 2>&1 || fail "dnf is required"

    log "Refreshing Rocky Linux package metadata (no distribution upgrade is run)..."
    root_command dnf makecache

    log "Installing OS prerequisites and bundled MongoDB Database Tools ${MONGO_TOOLS_VERSION}..."
    root_command dnf install -y \
        bash \
        ca-certificates \
        coreutils \
        findutils \
        gawk \
        grep \
        python3 \
        sed \
        "${ROCKY_MONGO_PACKAGE}"
}

install_packages() {
    case "${TARGET_OS}" in
        ubuntu) install_ubuntu_packages ;;
        rocky) install_rocky_packages ;;
        *) fail "Internal error: unsupported installation target ${TARGET_OS:-unset}" ;;
    esac
}

verify_installation() {
    local command_name
    for command_name in mongodump base64 awk find grep sed sort du python3; do
        command -v "${command_name}" >/dev/null 2>&1 ||
            fail "Installation completed but ${command_name} is not on PATH"
    done

    command -v sha256sum >/dev/null 2>&1 ||
        fail "Installation completed but sha256sum is not on PATH"

    mongodump --version | sed -n '1p'
    log "MongoDB tools and OS prerequisites are installed."
    if command -v kubectl >/dev/null 2>&1; then
        log "kubectl is present: $(command -v kubectl)"
    else
        log "kubectl is still required; install a version compatible with the target cluster."
    fi
}

main() {
    parse_arguments "$@"
    verify_bundle

    if [[ "${VERIFY_ONLY}" == true ]]; then
        log "Bundle verification completed; no host changes were made."
        exit 0
    fi

    validate_target
    install_packages
    verify_installation
}

main "$@"
