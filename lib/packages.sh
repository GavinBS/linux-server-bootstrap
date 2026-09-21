#!/usr/bin/env bash

logical_tools() {
    printf '%s\n' zsh neovim git curl fzf zoxide ripgrep fd bat eza tmux
}

tool_commands() {
    case "$1" in
        neovim) printf '%s\n' nvim ;;
        ripgrep) printf '%s\n' rg ;;
        fd) printf '%s\n' fd fdfind ;;
        bat) printf '%s\n' bat batcat ;;
        *) printf '%s\n' "$1" ;;
    esac
}

package_for() {
    local family=$1
    local logical=$2

    case "${family}:${logical}" in
        debian:fd) printf '%s\n' fd-find ;;
        debian:*) printf '%s\n' "$logical" ;;
        arch:*) printf '%s\n' "$logical" ;;
        fedora:fd) printf '%s\n' fd-find ;;
        fedora:*) printf '%s\n' "$logical" ;;
        *) return 1 ;;
    esac
}

tool_is_installed() {
    local logical=$1
    local candidate

    while IFS= read -r candidate; do
        if command_exists "$candidate"; then
            return 0
        fi
    done < <(tool_commands "$logical")
    return 1
}

tool_is_critical() {
    case "$1" in
        zsh | git | curl) return 0 ;;
        *) return 1 ;;
    esac
}

arch_sync_database_present() {
    local database
    for database in /var/lib/pacman/sync/*.db; do
        [[ -e $database ]] && return 0
    done
    return 1
}

prepare_package_manager() {
    case "$DISTRO_FAMILY" in
        debian)
            if [[ ${BOOTSTRAP_APT_INDEX_FRESH:-0} == 1 ]]; then
                log_skip 'APT package index was already updated by bootstrap.sh.'
            else
                log_info 'Updating APT package index...'
                if run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update; then
                    log_ok 'APT package index updated.'
                else
                    log_error 'apt-get update failed.'
                    return 1
                fi
            fi
            ;;
        arch)
            if ! arch_sync_database_present; then
                log_error 'No pacman sync database is present.'
                log_error 'Run a reviewed full system update (pacman -Syu), then rerun this bootstrap.'
                return 1
            fi
            log_info 'Using the existing pacman sync database; it will not be refreshed independently.'
            log_warn 'If packages cannot be installed, review and run pacman -Syu yourself before retrying.'
            ;;
        fedora)
            log_info 'DNF will install requested packages without performing a full system upgrade.'
            ;;
    esac
}

package_is_available() {
    local package=$1

    case "$DISTRO_FAMILY" in
        debian) apt-cache show --no-all-versions "$package" >/dev/null ;;
        arch) pacman -Si "$package" >/dev/null ;;
        fedora) dnf -q list --available "$package" >/dev/null ;;
        *) return 1 ;;
    esac
}

install_package() {
    local package=$1

    case "$DISTRO_FAMILY" in
        debian)
            run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package"
            ;;
        arch)
            run_privileged pacman -S --needed --noconfirm "$package"
            ;;
        fedora)
            run_privileged dnf install -y "$package"
            ;;
        *) return 1 ;;
    esac
}

install_requested_tools() {
    local logical package
    local -a missing_tools=()

    while IFS= read -r logical; do
        if tool_is_installed "$logical"; then
            ALREADY_INSTALLED+=("$logical")
            log_skip "${logical} already installed."
        else
            missing_tools+=("$logical")
        fi
    done < <(logical_tools)

    if ((${#missing_tools[@]} == 0)); then
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        for logical in "${missing_tools[@]}"; do
            package=$(package_for "$DISTRO_FAMILY" "$logical")
            log_plan "Would install ${logical} (package: ${package})."
            PLANNED_ITEMS+=("$logical")
        done
        return 0
    fi

    ensure_privilege_access || return 1
    prepare_package_manager || return 1

    for logical in "${missing_tools[@]}"; do
        package=$(package_for "$DISTRO_FAMILY" "$logical") || {
            log_error "No package mapping for ${logical} on ${DISTRO_FAMILY}."
            FAILED_ITEMS+=("$logical (no package mapping)")
            tool_is_critical "$logical" && return 1
            continue
        }

        log_info "Checking ${logical} package (${package})..."
        if ! package_is_available "$package"; then
            log_warn "${logical}: package ${package} is unavailable, or its repository query failed."
            FAILED_ITEMS+=("$logical (package unavailable or repository query failed)")
            if tool_is_critical "$logical"; then
                log_error "Critical tool ${logical} cannot be installed."
                return 1
            fi
            continue
        fi

        log_info "Installing ${logical}..."
        if install_package "$package" && tool_is_installed "$logical"; then
            INSTALLED_ITEMS+=("$logical")
            log_ok "${logical} installed."
        else
            log_warn "Failed to install or verify ${logical}."
            FAILED_ITEMS+=("$logical (installation failed)")
            if tool_is_critical "$logical"; then
                log_error "Critical tool ${logical} failed; stopping."
                return 1
            fi
        fi
    done
}
