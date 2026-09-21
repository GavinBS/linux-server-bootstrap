#!/usr/bin/env bash

# Shared logging and small portability helpers.

DRY_RUN=${DRY_RUN:-0}

log_info() { printf '[INFO] %s\n' "$*"; }
log_ok() { printf '[OK] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_skip() { printf '[SKIP] %s\n' "$*"; }
log_plan() { printf '[PLAN] %s\n' "$*"; }

die() {
    log_error "$*"
    return 1
}
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

checksum_file() {
    local file=$1

    if command_exists sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif command_exists shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        log_error 'Neither sha256sum nor shasum is available.'
        return 1
    fi
}

print_list() {
    local heading=$1
    shift

    printf '%s:\n' "$heading"
    if (($# == 0)); then
        printf '  (none)\n'
        return
    fi

    printf '  %s\n' "$@"
}
