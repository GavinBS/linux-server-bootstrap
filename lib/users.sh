#!/usr/bin/env bash

# User resolution and narrowly scoped privilege changes.

lookup_user_record() {
    local username=$1

    if [[ -n ${BOOTSTRAP_PASSWD_RECORD:-} ]]; then
        printf '%s\n' "$BOOTSTRAP_PASSWD_RECORD"
        return 0
    fi

    if ! command_exists getent; then
        log_error 'getent is required to resolve user home directories safely.'
        return 1
    fi
    getent passwd "$username"
}

resolve_target_user() {
    local requested_user=${1:-}
    local force_system_only=${2:-0}
    local current_uid=${BOOTSTRAP_EUID:-$EUID}
    local current_user record home shell
    local -a fields

    current_user=${BOOTSTRAP_CURRENT_USER:-$(id -un)}
    SYSTEM_ONLY=$force_system_only

    if [[ $current_uid -eq 0 && -z $requested_user ]]; then
        SYSTEM_ONLY=1
        TARGET_USER=
        TARGET_HOME=
        TARGET_GROUP=
        TARGET_SHELL=
        log_warn 'Running as root without --user: only system packages will be installed; user dotfiles and shell changes are disabled.'
        return 0
    fi

    TARGET_USER=${requested_user:-$current_user}
    if [[ $TARGET_USER == root ]]; then
        log_error 'Root is not accepted as a dotfiles target. Omit --user for system-only mode or choose a normal user.'
        return 1
    fi
    if [[ $current_uid -ne 0 && $TARGET_USER != "$current_user" ]]; then
        log_error "A non-root process may configure only its current user (${current_user})."
        return 1
    fi

    if ! record=$(lookup_user_record "$TARGET_USER"); then
        log_error "User does not exist: ${TARGET_USER}"
        return 1
    fi
    IFS=: read -r -a fields <<<"$record"
    TARGET_USER=${fields[0]:-}
    home=${fields[5]:-}
    shell=${fields[6]:-}
    if [[ -z $TARGET_USER || -z $home || $home != /* ]]; then
        log_error "Could not determine a safe absolute home directory for ${requested_user:-$current_user}."
        return 1
    fi

    TARGET_HOME=$home
    TARGET_SHELL=$shell
    if [[ -n ${BOOTSTRAP_TARGET_GROUP:-} ]]; then
        TARGET_GROUP=$BOOTSTRAP_TARGET_GROUP
    else
        TARGET_GROUP=$(id -gn "$TARGET_USER") || return 1
    fi

    if [[ ! -d $TARGET_HOME ]]; then
        log_error "Target home directory does not exist: ${TARGET_HOME}"
        return 1
    fi
}

ensure_privilege_access() {
    if [[ ${BOOTSTRAP_EUID:-$EUID} -eq 0 ]]; then
        return 0
    fi
    if ! command_exists sudo; then
        log_error 'sudo is required for package installation when not running as root.'
        return 1
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log_plan 'Would validate sudo access before system changes.'
        return 0
    fi
    log_info 'Validating sudo access...'
    sudo -v
}

run_privileged() {
    if [[ ${BOOTSTRAP_EUID:-$EUID} -eq 0 ]]; then
        "$@"
    else
        sudo -- "$@"
    fi
}

run_as_target() {
    local current_user
    current_user=${BOOTSTRAP_CURRENT_USER:-$(id -un)}

    if [[ ${BOOTSTRAP_EUID:-$EUID} -ne 0 || $TARGET_USER == "$current_user" ]]; then
        HOME=$TARGET_HOME "$@"
    elif command_exists sudo; then
        sudo -u "$TARGET_USER" -H -- "$@"
    elif command_exists runuser; then
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    else
        log_error 'Neither sudo nor runuser is available to run a command as the target user.'
        return 1
    fi
}

ensure_target_directory() {
    local directory=$1
    local mode=${2:-0755}

    if [[ -d $directory ]]; then
        if [[ $DRY_RUN -eq 0 && ${BOOTSTRAP_EUID:-$EUID} -eq 0 ]]; then
            chown "$TARGET_USER:$TARGET_GROUP" "$directory"
        fi
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log_plan "Would create directory ${directory} (mode ${mode}, owner ${TARGET_USER}:${TARGET_GROUP})."
        return 0
    fi

    if [[ ${BOOTSTRAP_EUID:-$EUID} -eq 0 ]]; then
        install -d -m "$mode" -o "$TARGET_USER" -g "$TARGET_GROUP" "$directory"
    else
        install -d -m "$mode" "$directory"
    fi
}

find_zsh_path() {
    command -v zsh
}

configure_default_shell() {
    local zsh_path current_record current_shell

    if [[ $SYSTEM_ONLY -eq 1 || -z ${TARGET_USER:-} ]]; then
        log_warn 'Default shell change skipped because no target user is selected.'
        return 1
    fi
    if ! zsh_path=$(find_zsh_path); then
        log_warn 'Cannot set the default shell because zsh is not installed.'
        return 1
    fi

    current_record=$(lookup_user_record "$TARGET_USER") || return 1
    current_shell=${current_record##*:}
    if [[ $current_shell == "$zsh_path" ]]; then
        log_skip "${TARGET_USER}'s default shell is already ${zsh_path}."
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ ! -r /etc/shells ]]; then
            log_plan "Would inspect /etc/shells and add ${zsh_path} if needed."
        elif ! grep -Fxq "$zsh_path" /etc/shells; then
            log_plan "Would add ${zsh_path} to /etc/shells."
        fi
        log_plan "Would change ${TARGET_USER}'s default shell from ${current_shell} to ${zsh_path}."
        return 0
    fi

    if ! grep -Fxq "$zsh_path" /etc/shells; then
        log_info "Adding ${zsh_path} to /etc/shells..."
        run_privileged sh -c 'printf "%s\n" "$1" >> /etc/shells' sh "$zsh_path" || return 1
    fi
    if ! command_exists chsh; then
        log_warn 'chsh is unavailable; the default shell was not changed.'
        return 1
    fi
    if ! run_privileged chsh -s "$zsh_path" "$TARGET_USER"; then
        log_warn "Failed to change ${TARGET_USER}'s default shell; the existing shell remains unchanged."
        return 1
    fi

    log_ok "Default shell changed to ${zsh_path} for ${TARGET_USER}."
    printf 'Log out and log back in for the new default shell to take effect.\n'
}
