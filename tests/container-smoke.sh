#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ENGINE=${CONTAINER_ENGINE:-}

if [[ -z $ENGINE ]]; then
    if command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    else
        printf '[SKIP] docker or podman is required for container smoke tests.\n'
        exit 0
    fi
fi

images=(
    debian:stable-slim
    ubuntu:24.04
    archlinux:latest
    fedora:latest
)

for image in "${images[@]}"; do
    printf '[INFO] Testing %s\n' "$image"
    "$ENGINE" run --rm \
        --volume "$PROJECT_ROOT:/project:ro" \
        --workdir /project \
        "$image" \
        bash -c 'bash -n bootstrap.sh install.sh lib/*.sh tests/*.sh && bash bootstrap.sh --dry-run --ref v1.0.0 && bash install.sh --dry-run'
    printf '[OK] %s\n' "$image"
done
