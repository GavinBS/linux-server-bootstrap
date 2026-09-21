#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=lib/common.sh
. "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=lib/distro.sh
. "$PROJECT_ROOT/lib/distro.sh"
# shellcheck source=lib/users.sh
. "$PROJECT_ROOT/lib/users.sh"
# shellcheck source=lib/packages.sh
. "$PROJECT_ROOT/lib/packages.sh"
# shellcheck source=lib/dotfiles.sh
. "$PROJECT_ROOT/lib/dotfiles.sh"

REQUESTED_USER=
SET_SHELL=0
SYSTEM_ONLY_REQUESTED=0
INSTALLED_ITEMS=()
ALREADY_INSTALLED=()
PLANNED_ITEMS=()
SKIPPED_ITEMS=()
FAILED_ITEMS=()

usage() {
    cat <<'EOF'
Usage: bash install.sh [options]

Options:
  --dry-run       Show planned changes without modifying the system
  --user USER     Deploy user configuration for USER (required for root)
  --set-shell     Set zsh as the target user's default shell
  --system-only   Install packages but do not deploy user configuration
  -h, --help      Show this help
EOF
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --set-shell) SET_SHELL=1 ;;
            --system-only) SYSTEM_ONLY_REQUESTED=1 ;;
            --user)
                shift
                [[ $# -gt 0 && -n $1 ]] || die '--user requires a username.'
                REQUESTED_USER=$1
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
}

verify_installation() {
    local logical path expected_owner actual_owner
    local verification_failed=0

    [[ $DRY_RUN -eq 1 ]] && return 0
    log_info 'Verifying installation...'
    while IFS= read -r logical; do
        if ! tool_is_installed "$logical"; then
            log_warn "Verification: ${logical} command is unavailable."
            verification_failed=1
        fi
    done < <(logical_tools)

    if [[ $SYSTEM_ONLY -eq 0 ]]; then
        expected_owner="${TARGET_USER}:${TARGET_GROUP}"
        for path in \
            "$TARGET_HOME/.zshrc" \
            "$TARGET_HOME/.config/nvim/init.lua" \
            "$TARGET_HOME/.config/tmux/tmux.conf" \
            "$TARGET_HOME/.tmux.conf"; do
            [[ -f $path ]] || {
                log_warn "Verification: missing ${path}."
                verification_failed=1
                continue
            }
            if stat --version >/dev/null 2>&1; then
                actual_owner=$(stat -c '%U:%G' "$path")
                if [[ $actual_owner != "$expected_owner" ]]; then
                    log_warn "Verification: ${path} is owned by ${actual_owner}, expected ${expected_owner}."
                    verification_failed=1
                fi
            fi
        done
    fi

    if [[ $verification_failed -eq 0 ]]; then
        log_ok 'Verification completed.'
    else
        FAILED_ITEMS+=("verification (one or more checks failed)")
    fi
}

print_summary() {
    printf '\nInstallation summary\n\n'
    print_list 'Installed' "${INSTALLED_ITEMS[@]}"
    print_list 'Already installed' "${ALREADY_INSTALLED[@]}"
    if [[ $DRY_RUN -eq 1 ]]; then
        print_list 'Planned package installations' "${PLANNED_ITEMS[@]}"
    fi
    print_list 'Skipped' "${SKIPPED_ITEMS[@]}"
    print_list 'Failed' "${FAILED_ITEMS[@]}"
}

main() {
    parse_arguments "$@"

    if [[ $(uname -s) != Linux && -z ${OS_RELEASE_FILE:-} ]]; then
        die 'This installer supports Linux only.'
    fi

    log_info 'Detecting Linux distribution...'
    detect_distribution || exit 1
    log_ok "${DISTRO_NAME} detected (${PKG_MANAGER})."

    log_info 'Detecting CPU architecture...'
    detect_architecture "${BOOTSTRAP_MACHINE:-}" || exit 1
    log_ok "Architecture: ${ARCH}."

    resolve_target_user "$REQUESTED_USER" "$SYSTEM_ONLY_REQUESTED" || exit 1
    if [[ $SYSTEM_ONLY -eq 0 ]]; then
        log_info "Target user: ${TARGET_USER} (${TARGET_HOME})."
    fi

    if ! install_requested_tools; then
        print_summary
        exit 1
    fi

    if [[ $SYSTEM_ONLY -eq 0 ]]; then
        log_info 'Deploying user configuration...'
        if ! deploy_dotfiles; then
            log_warn 'One or more configuration files require manual attention.'
        fi
    else
        SKIPPED_ITEMS+=("user dotfiles (system-only mode)")
    fi

    if [[ $SET_SHELL -eq 1 ]]; then
        if ! configure_default_shell; then
            FAILED_ITEMS+=("default shell change")
        fi
    else
        SKIPPED_ITEMS+=("default shell change (use --set-shell to enable)")
    fi

    verify_installation
    print_summary

    if [[ $DRY_RUN -eq 1 ]]; then
        log_ok 'Dry run completed; no system state was changed.'
    fi
    if ((${#FAILED_ITEMS[@]} > 0)); then
        log_warn 'Completed with one or more non-critical failures.'
        exit 2
    fi
    log_ok 'Linux terminal environment setup completed.'
}

main "$@"
