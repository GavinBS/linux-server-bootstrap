#!/usr/bin/env bash

managed_state_file() {
    local destination=$1
    local relative key

    relative=${destination#"$TARGET_HOME"/}
    key=${relative//\//__}
    printf '%s/%s.sha256\n' "$TARGET_HOME/.local/state/linux-server-bootstrap" "$key"
}

read_managed_hash() {
    local destination=$1
    local state_file
    state_file=$(managed_state_file "$destination")
    [[ -r $state_file ]] || return 1
    IFS= read -r REPLY <"$state_file"
    [[ $REPLY =~ ^[0-9a-fA-F]{64}$ ]]
}

write_managed_hash() {
    local destination=$1
    local hash=$2
    local state_file state_dir temporary

    state_file=$(managed_state_file "$destination")
    state_dir=${state_file%/*}
    ensure_target_directory "$state_dir" 0700 || return 1
    temporary=$(mktemp "${state_file}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$hash" >"$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    chmod 0600 "$temporary"
    if [[ ${BOOTSTRAP_EUID:-$EUID} -eq 0 ]]; then
        chown "$TARGET_USER:$TARGET_GROUP" "$temporary"
    fi
    mv -f -- "$temporary" "$state_file"
}

deploy_file() {
    local source=$1
    local destination=$2
    local mode=${3:-0644}
    local parent backup previous_hash current_hash source_hash temporary

    case "$destination" in
        "$TARGET_HOME"/*) ;;
        *)
            log_error "Refusing to deploy outside the target home: ${destination}"
            return 1
            ;;
    esac
    if [[ ! -f $source ]]; then
        log_error "Managed source file is missing: ${source}"
        return 1
    fi
    if [[ -d $destination ]]; then
        log_error "Cannot replace a directory with a managed file: ${destination}"
        return 1
    fi

    if [[ -e $destination || -L $destination ]]; then
        if cmp -s -- "$source" "$destination"; then
            log_skip "${destination} is already current."
            source_hash=$(checksum_file "$source") || return 1
            [[ $DRY_RUN -eq 1 ]] || write_managed_hash "$destination" "$source_hash"
            return 0
        fi
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ -e $destination || -L $destination ]]; then
            backup="${destination}.bootstrap-backup"
            if [[ -e $backup || -L $backup ]]; then
                log_plan "Would preserve existing backup and only replace ${destination} if it is a previously managed file."
            else
                log_plan "Would back up ${destination} to ${backup}, then install the managed file."
            fi
        else
            log_plan "Would install ${destination}."
        fi
        return 0
    fi

    if [[ -e $destination || -L $destination ]]; then
        current_hash=$(checksum_file "$destination") || return 1
        previous_hash=
        if read_managed_hash "$destination"; then
            previous_hash=$REPLY
        fi

        if [[ -z $previous_hash || $previous_hash != "$current_hash" ]]; then
            backup="${destination}.bootstrap-backup"
            if [[ -e $backup || -L $backup ]]; then
                log_warn "Refusing to overwrite user-modified file because its one-time backup already exists: ${destination}"
                return 1
            fi
            log_info "Backing up existing file to ${backup}..."
            cp -pP -- "$destination" "$backup" || return 1
            if [[ ${BOOTSTRAP_EUID:-$EUID} -eq 0 ]]; then
                chown -h "$TARGET_USER:$TARGET_GROUP" "$backup"
            fi
        fi
    fi

    parent=${destination%/*}
    ensure_target_directory "$parent" 0755 || return 1
    temporary=$(mktemp "${destination}.bootstrap-tmp.XXXXXX") || return 1
    if ! install -m "$mode" "$source" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if [[ ${BOOTSTRAP_EUID:-$EUID} -eq 0 ]]; then
        chown "$TARGET_USER:$TARGET_GROUP" "$temporary"
    fi
    mv -f -- "$temporary" "$destination"

    source_hash=$(checksum_file "$source") || return 1
    write_managed_hash "$destination" "$source_hash" || return 1
    log_ok "Installed ${destination}."
}

deploy_dotfiles() {
    local failed=0

    deploy_file "$PROJECT_ROOT/dotfiles/.zshrc" "$TARGET_HOME/.zshrc" 0644 || {
        FAILED_ITEMS+=("~/.zshrc (configuration conflict)")
        failed=1
    }
    deploy_file "$PROJECT_ROOT/dotfiles/.config/nvim/init.lua" "$TARGET_HOME/.config/nvim/init.lua" 0644 || {
        FAILED_ITEMS+=("~/.config/nvim/init.lua (configuration conflict)")
        failed=1
    }
    deploy_file "$PROJECT_ROOT/dotfiles/.config/tmux/tmux.conf" "$TARGET_HOME/.config/tmux/tmux.conf" 0644 || {
        FAILED_ITEMS+=("~/.config/tmux/tmux.conf (configuration conflict)")
        failed=1
    }
    deploy_file "$PROJECT_ROOT/dotfiles/.tmux.conf" "$TARGET_HOME/.tmux.conf" 0644 || {
        FAILED_ITEMS+=("~/.tmux.conf (configuration conflict)")
        failed=1
    }

    return "$failed"
}
