#!/usr/bin/env bash
set -Eeuo pipefail

# Replace USER before publishing this repository, or set BOOTSTRAP_REPO_URL.
DEFAULT_REPO_URL='https://github.com/USER/linux-server-bootstrap.git'
REPO_URL=${BOOTSTRAP_REPO_URL:-$DEFAULT_REPO_URL}
REF=main
DRY_RUN=0
SET_SHELL=0
REQUESTED_USER=
SYSTEM_ONLY=0
TARGET_USER=
TARGET_HOME=
TARGET_GROUP=
DISTRO_ID=
DISTRO_NAME=
DISTRO_FAMILY=
ARCH=
APT_INDEX_UPDATED=0

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die() { error "$*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Usage: bash bootstrap.sh [options]

Options:
  --dry-run       Show planned changes without modifying the system
  --user USER     Deploy configuration for USER (required for root user setup)
  --set-shell     Set zsh as the target user's default shell
  --ref REF       Git tag, branch, or full commit to install (default: main)
  -h, --help      Show this help

Environment:
  BOOTSTRAP_REPO_URL         Override the public GitHub repository URL
  BOOTSTRAP_REPO_DIR         Override the checkout directory
  BOOTSTRAP_EXPECTED_COMMIT  Require FETCH_HEAD to equal this full commit ID
EOF
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --set-shell) SET_SHELL=1 ;;
            --user)
                shift
                [[ $# -gt 0 && -n $1 ]] || die '--user requires a username.'
                REQUESTED_USER=$1
                ;;
            --ref)
                shift
                [[ $# -gt 0 && -n $1 ]] || die '--ref requires a Git ref.'
                REF=$1
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done

    if [[ ! $REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ || $REF == *..* || $REF == *@\{* ]]; then
        die "Unsafe or invalid Git ref: ${REF}"
    fi
}

detect_system() {
    local machine system_name os_release

    system_name=${BOOTSTRAP_UNAME_S:-$(uname -s)}
    os_release=${BOOTSTRAP_OS_RELEASE_FILE:-/etc/os-release}
    [[ $system_name == Linux ]] || die 'This bootstrap supports Linux only.'
    [[ -r $os_release ]] || die "Cannot read ${os_release}."

    DISTRO_ID=$(
        # shellcheck disable=SC1090
        . "$os_release"
        printf '%s' "${ID:-}"
    )
    DISTRO_NAME=$(
        # shellcheck disable=SC1090
        . "$os_release"
        printf '%s' "${PRETTY_NAME:-${NAME:-${ID:-unknown}}}"
    )
    DISTRO_ID=${DISTRO_ID,,}
    case "$DISTRO_ID" in
        debian | ubuntu) DISTRO_FAMILY=debian ;;
        arch) DISTRO_FAMILY=arch ;;
        fedora) DISTRO_FAMILY=fedora ;;
        *) die "Unsupported Linux distribution: ${DISTRO_NAME} (ID=${DISTRO_ID:-unknown})." ;;
    esac

    machine=${BOOTSTRAP_MACHINE:-$(uname -m)}
    case "$machine" in
        x86_64 | amd64) ARCH=x86_64 ;;
        aarch64 | arm64) ARCH=aarch64 ;;
        *) die "Unsupported CPU architecture: ${machine}." ;;
    esac
}

lookup_user() {
    local username=$1
    command_exists getent || die 'getent is required to resolve the target user safely.'
    getent passwd "$username"
}

resolve_user() {
    local current_user record home
    local -a fields
    current_user=$(id -un)

    if [[ $EUID -eq 0 && -z $REQUESTED_USER ]]; then
        SYSTEM_ONLY=1
        warn 'Running as root without --user: installing system packages only; dotfiles and shell changes are disabled.'
        return
    fi

    TARGET_USER=${REQUESTED_USER:-$current_user}
    [[ $TARGET_USER != root ]] || die 'Root is not accepted as a dotfiles target.'
    if [[ $EUID -ne 0 && $TARGET_USER != "$current_user" ]]; then
        die "A non-root process may configure only ${current_user}."
    fi
    record=$(lookup_user "$TARGET_USER") || die "User does not exist: ${TARGET_USER}"
    IFS=: read -r -a fields <<<"$record"
    TARGET_USER=${fields[0]:-}
    home=${fields[5]:-}
    [[ -n $home && $home == /* ]] || die "Cannot determine a safe home for ${TARGET_USER}."
    [[ -d $home ]] || die "Target home does not exist: ${home}"
    TARGET_HOME=$home
    TARGET_GROUP=$(id -gn "$TARGET_USER") || die "Cannot determine group for ${TARGET_USER}."
}

as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo -- "$@"
    fi
}

ensure_privilege() {
    [[ $EUID -eq 0 ]] && return
    command_exists sudo || die 'sudo is required to install Git.'
    sudo -v
}

arch_database_present() {
    local database
    for database in /var/lib/pacman/sync/*.db; do
        [[ -e $database ]] && return 0
    done
    return 1
}

install_git() {
    command_exists git && {
        ok 'Git is already installed.'
        return
    }
    ensure_privilege
    info 'Installing the minimal Git dependency...'
    case "$DISTRO_FAMILY" in
        debian)
            as_root env DEBIAN_FRONTEND=noninteractive apt-get update
            APT_INDEX_UPDATED=1
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git
            ;;
        arch)
            arch_database_present || die 'No pacman sync database exists. Review and run pacman -Syu, then retry.'
            as_root pacman -S --needed --noconfirm git
            ;;
        fedora) as_root dnf install -y git ;;
    esac
    command_exists git || die 'Git installation did not provide the git command.'
    ok 'Git installed.'
}

run_as_target() {
    local current_user
    current_user=$(id -un)
    if [[ $SYSTEM_ONLY -eq 1 || $EUID -ne 0 || $TARGET_USER == "$current_user" ]]; then
        "$@"
    elif command_exists sudo; then
        sudo -u "$TARGET_USER" -H -- "$@"
    elif command_exists runuser; then
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    else
        die 'Neither sudo nor runuser can execute Git as the target user.'
    fi
}

normalize_repo_url() {
    local value=$1
    value=${value%/}
    value=${value%.git}
    printf '%s\n' "$value"
}

repository_matches() {
    local directory=$1
    local expected=$2
    local actual

    [[ -d $directory/.git ]] || return 1
    actual=$(run_as_target git -C "$directory" remote get-url origin) || return 1
    [[ $(normalize_repo_url "$actual") == "$(normalize_repo_url "$expected")" ]]
}

verify_fetched_commit() {
    local directory=$1
    local expected=${BOOTSTRAP_EXPECTED_COMMIT:-}
    local actual

    [[ -z $expected ]] && return 0
    [[ $expected =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]] || die 'BOOTSTRAP_EXPECTED_COMMIT must be a full 40- or 64-character commit ID.'
    actual=$(run_as_target git -C "$directory" rev-parse FETCH_HEAD)
    [[ ${actual,,} == "${expected,,}" ]] || die "Fetched commit ${actual} does not match expected commit ${expected}."
}

prepare_parent_directory() {
    local parent=$1
    if [[ $SYSTEM_ONLY -eq 1 ]]; then
        install -d -m 0755 "$parent"
    elif [[ $EUID -eq 0 ]]; then
        install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$parent"
    else
        install -d -m 0755 "$parent"
    fi
}

prepare_repository() {
    local directory=$1
    local parent temporary checkout dirty

    if [[ -e $directory ]]; then
        if ! repository_matches "$directory" "$REPO_URL"; then
            die "Existing path is not the expected repository: ${directory}"
        fi
        dirty=$(run_as_target git -C "$directory" status --porcelain)
        [[ -z $dirty ]] || die "Repository has local changes; refusing to update it: ${directory}"
        info "Fetching ${REF} in existing repository..."
        run_as_target git -C "$directory" fetch --depth=1 origin "$REF"
        verify_fetched_commit "$directory"
        run_as_target git -C "$directory" checkout --detach FETCH_HEAD
        ok "Repository updated to $(run_as_target git -C "$directory" rev-parse --short HEAD)."
        return
    fi

    parent=${directory%/*}
    prepare_parent_directory "$parent"
    temporary=$(run_as_target mktemp -d "${directory}.clone.XXXXXX") || die 'Could not create a repository staging directory.'
    checkout="$temporary/checkout"
    info "Fetching ${REPO_URL} at ${REF}..."
    if ! run_as_target git init -q "$checkout" ||
        ! run_as_target git -C "$checkout" remote add origin "$REPO_URL" ||
        ! run_as_target git -C "$checkout" fetch --depth=1 origin "$REF"; then
        error "Repository fetch failed. The incomplete staging directory was preserved for inspection: ${temporary}"
        exit 1
    fi
    verify_fetched_commit "$checkout"
    run_as_target git -C "$checkout" checkout --detach FETCH_HEAD
    run_as_target mv -- "$checkout" "$directory"
    run_as_target rmdir -- "$temporary"
    ok "Repository installed at ${directory}."
}

show_dry_run() {
    local target_description repo_directory logical package
    if [[ $SYSTEM_ONLY -eq 1 ]]; then
        target_description='system packages only (root without --user)'
        repo_directory=${BOOTSTRAP_REPO_DIR:-/var/lib/linux-server-bootstrap}
    else
        target_description="${TARGET_USER} (${TARGET_HOME})"
        repo_directory=${BOOTSTRAP_REPO_DIR:-$TARGET_HOME/.local/share/linux-server-bootstrap}
    fi

    printf '\nDry-run plan\n\n'
    printf 'Distribution: %s\nArchitecture: %s\nTarget: %s\n' "$DISTRO_NAME" "$ARCH" "$target_description"
    printf 'Repository: %s\nRef: %s\nCheckout: %s\n' "$REPO_URL" "$REF" "$repo_directory"
    printf 'Packages:\n'
    for logical in zsh neovim git curl fzf zoxide ripgrep fd bat eza tmux; do
        package=$logical
        [[ $DISTRO_FAMILY == debian && $logical == fd ]] && package=fd-find
        [[ $DISTRO_FAMILY == fedora && $logical == fd ]] && package=fd-find
        printf '  %s (%s)\n' "$logical" "$package"
    done
    if [[ $SYSTEM_ONLY -eq 0 ]]; then
        printf 'Configuration files:\n'
        printf '  %s\n' \
            "$TARGET_HOME/.zshrc" \
            "$TARGET_HOME/.config/nvim/init.lua" \
            "$TARGET_HOME/.config/tmux/tmux.conf" \
            "$TARGET_HOME/.tmux.conf"
        if [[ $SET_SHELL -eq 1 ]]; then
            printf 'Default shell: would set zsh for %s after validation\n' "$TARGET_USER"
        else
            printf 'Default shell: unchanged\n'
        fi
    fi
    printf '\n[OK] Dry run completed; no system state was changed.\n'
}

main() {
    local repo_directory
    local -a installer_args=()

    parse_arguments "$@"
    info 'Detecting Linux system...'
    detect_system
    ok "${DISTRO_NAME} on ${ARCH} detected."
    resolve_user

    if [[ $SYSTEM_ONLY -eq 1 ]]; then
        repo_directory=${BOOTSTRAP_REPO_DIR:-/var/lib/linux-server-bootstrap}
    else
        repo_directory=${BOOTSTRAP_REPO_DIR:-$TARGET_HOME/.local/share/linux-server-bootstrap}
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        show_dry_run
        return
    fi
    [[ $REPO_URL != *'/USER/'* ]] || die 'Set your GitHub username in DEFAULT_REPO_URL or export BOOTSTRAP_REPO_URL before running.'

    install_git
    prepare_repository "$repo_directory"

    [[ $SYSTEM_ONLY -eq 1 ]] && installer_args+=(--system-only)
    [[ -n $REQUESTED_USER ]] && installer_args+=(--user "$REQUESTED_USER")
    [[ $SET_SHELL -eq 1 ]] && installer_args+=(--set-shell)
    info 'Starting the full installer...'
    export BOOTSTRAP_APT_INDEX_FRESH=$APT_INDEX_UPDATED
    exec bash "$repo_directory/install.sh" "${installer_args[@]}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
