#!/usr/bin/env bash

# Distribution and architecture detection. Tests may override OS_RELEASE_FILE
# and pass an explicit machine value to detect_architecture.

detect_distribution() {
    local os_release=${OS_RELEASE_FILE:-/etc/os-release}
    local detected_id detected_name

    if [[ ! -r $os_release ]]; then
        log_error "Cannot read ${os_release}; only Linux systems with /etc/os-release are supported."
        return 1
    fi

    detected_id=$(
        # /etc/os-release is a distribution-owned shell-compatible data file.
        # shellcheck disable=SC1090
        . "$os_release"
        printf '%s' "${ID:-}"
    )
    detected_name=$(
        # shellcheck disable=SC1090
        . "$os_release"
        printf '%s' "${PRETTY_NAME:-${NAME:-${ID:-unknown}}}"
    )

    DISTRO_ID=${detected_id,,}
    DISTRO_NAME=$detected_name

    case "$DISTRO_ID" in
        debian | ubuntu)
            DISTRO_FAMILY=debian
            PKG_MANAGER=apt-get
            ;;
        arch)
            DISTRO_FAMILY=arch
            PKG_MANAGER=pacman
            ;;
        fedora)
            DISTRO_FAMILY=fedora
            PKG_MANAGER=dnf
            ;;
        *)
            log_error "Unsupported Linux distribution: ${DISTRO_NAME} (ID=${DISTRO_ID:-unknown})."
            log_error 'Supported distributions: Debian, Ubuntu, Arch Linux, and Fedora.'
            return 1
            ;;
    esac
}
detect_architecture() {
    local machine=${1:-}

    if [[ -z $machine ]]; then
        machine=$(uname -m)
    fi

    case "$machine" in
        x86_64 | amd64)
            ARCH=x86_64
            ;;
        aarch64 | arm64)
            ARCH=aarch64
            ;;
        *)
            log_error "Unsupported CPU architecture: ${machine}."
            log_error 'Supported architectures: x86_64/amd64 and aarch64/arm64.'
            return 1
            ;;
    esac
}
