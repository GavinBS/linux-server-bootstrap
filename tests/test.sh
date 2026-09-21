#!/usr/bin/env bash
set -uo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/linux-server-bootstrap-tests.XXXXXX")
trap 'rm -rf -- "$TEST_TMP"' EXIT

# shellcheck source=../lib/common.sh
. "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=../lib/distro.sh
. "$PROJECT_ROOT/lib/distro.sh"
# shellcheck source=../lib/users.sh
. "$PROJECT_ROOT/lib/users.sh"
# shellcheck source=../lib/packages.sh
. "$PROJECT_ROOT/lib/packages.sh"
# shellcheck source=../lib/dotfiles.sh
. "$PROJECT_ROOT/lib/dotfiles.sh"

TESTS=0
FAILURES=0

pass() {
    TESTS=$((TESTS + 1))
    printf '[PASS] %s\n' "$1"
}

fail() {
    TESTS=$((TESTS + 1))
    FAILURES=$((FAILURES + 1))
    printf '[FAIL] %s\n' "$1" >&2
}

assert_equal() {
    local expected=$1 actual=$2 label=$3
    if [[ $actual == "$expected" ]]; then
        pass "$label"
    else
        fail "$label (expected: ${expected}; actual: ${actual})"
    fi
}

assert_success() {
    local label=$1
    shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

assert_failure() {
    local label=$1
    shift
    if "$@"; then fail "$label (unexpected success)"; else pass "$label"; fi
}

write_os_release() {
    local id=$1 name=$2 file=$3
    printf 'ID=%s\nPRETTY_NAME="%s"\n' "$id" "$name" >"$file"
}

test_distribution_detection() {
    local id expected_family expected_manager fixture
    fixture="$TEST_TMP/os-release"
    while IFS=: read -r id expected_family expected_manager; do
        write_os_release "$id" "Test ${id}" "$fixture"
        OS_RELEASE_FILE=$fixture
        if detect_distribution; then
            assert_equal "$expected_family" "$DISTRO_FAMILY" "detect ${id} family"
            assert_equal "$expected_manager" "$PKG_MANAGER" "detect ${id} package manager"
        else
            fail "detect supported distribution ${id}"
        fi
    done <<'EOF'
debian:debian:apt-get
ubuntu:debian:apt-get
arch:arch:pacman
fedora:fedora:dnf
EOF

    write_os_release alpine 'Alpine Linux' "$fixture"
    OS_RELEASE_FILE=$fixture
    assert_failure 'reject unsupported distribution' detect_distribution
}

test_architecture_detection() {
    local input expected
    while IFS=: read -r input expected; do
        detect_architecture "$input"
        assert_equal "$expected" "$ARCH" "map architecture ${input}"
    done <<'EOF'
x86_64:x86_64
amd64:x86_64
aarch64:aarch64
arm64:aarch64
EOF
    assert_failure 'reject unsupported architecture' detect_architecture riscv64
}

test_package_mapping() {
    assert_equal fd-find "$(package_for debian fd)" 'Debian fd package mapping'
    assert_equal bat "$(package_for debian bat)" 'Debian bat package mapping'
    assert_equal fd "$(package_for arch fd)" 'Arch fd package mapping'
    assert_equal eza "$(package_for arch eza)" 'Arch eza package mapping'
    assert_equal fd-find "$(package_for fedora fd)" 'Fedora fd package mapping'
    assert_equal neovim "$(package_for fedora neovim)" 'Fedora Neovim package mapping'

    DISTRO_FAMILY=debian
    BOOTSTRAP_APT_INDEX_FRESH=1
    assert_success 'APT refresh is not repeated after bootstrap refreshed it' prepare_package_manager
    unset BOOTSTRAP_APT_INDEX_FRESH
}

test_user_resolution() {
    local user group uid home
    user=$(id -un)
    group=$(id -gn)
    uid=$(id -u)
    home="$TEST_TMP/user-home"
    mkdir -p "$home"

    BOOTSTRAP_EUID=$uid
    BOOTSTRAP_CURRENT_USER=$user
    BOOTSTRAP_TARGET_GROUP=$group
    BOOTSTRAP_PASSWD_RECORD="${user}:x:${uid}:$(id -g)::${home}:/bin/sh"
    resolve_target_user '' 0
    assert_equal "$user" "$TARGET_USER" 'ordinary user defaults to current user'
    assert_equal "$home" "$TARGET_HOME" 'HOME comes from passwd database record'

    BOOTSTRAP_EUID=0
    unset BOOTSTRAP_PASSWD_RECORD
    resolve_target_user '' 0
    assert_equal 1 "$SYSTEM_ONLY" 'root without --user selects system-only mode'

    BOOTSTRAP_PASSWD_RECORD="${user}:x:${uid}:$(id -g)::${home}:/bin/sh"
    resolve_target_user "$user" 0
    assert_equal "$home" "$TARGET_HOME" 'root with --user resolves target HOME'
}

portable_owner() {
    local path=$1
    if stat --version >/dev/null 2>&1; then
        stat -c '%U:%G' "$path"
    else
        stat -f '%Su:%Sg' "$path"
    fi
}

repository_preparation_fails() {
    (prepare_repository "$1")
}

test_dotfile_deployment() {
    local user group home source destination backup before after
    user=$(id -un)
    group=$(id -gn)
    home="$TEST_TMP/dotfiles-home"
    source="$TEST_TMP/source.conf"
    destination="$home/.config/example.conf"
    backup="${destination}.bootstrap-backup"
    mkdir -p "$home/.config"
    printf 'managed-v1\n' >"$source"
    printf 'user-original\n' >"$destination"

    TARGET_USER=$user
    TARGET_GROUP=$group
    TARGET_HOME=$home
    BOOTSTRAP_EUID=$(id -u)
    DRY_RUN=0

    assert_success 'existing configuration is backed up and deployed' deploy_file "$source" "$destination" 0644
    assert_equal 'user-original' "$(<"$backup")" 'backup preserves original content'
    assert_equal 'managed-v1' "$(<"$destination")" 'managed content is installed'
    assert_equal "${user}:${group}" "$(portable_owner "$destination")" 'deployed file ownership is correct'

    before=$(checksum_file "$destination")
    assert_success 'identical deployment is idempotent' deploy_file "$source" "$destination" 0644
    after=$(checksum_file "$destination")
    assert_equal "$before" "$after" 'repeat deployment leaves content unchanged'

    printf 'managed-v2\n' >"$source"
    assert_success 'previously managed file can be upgraded safely' deploy_file "$source" "$destination" 0644
    assert_equal 'managed-v2' "$(<"$destination")" 'managed upgrade installs new content'

    printf 'user-edit\n' >"$destination"
    printf 'managed-v3\n' >"$source"
    assert_failure 'user edit is not overwritten when one-time backup exists' deploy_file "$source" "$destination" 0644
    assert_equal 'user-edit' "$(<"$destination")" 'conflicting user edit remains intact'
    assert_equal 'user-original' "$(<"$backup")" 'one-time backup is not multiplied or replaced'
}

test_dry_run_no_changes() {
    local user group uid home fixture before after output
    user=$(id -un)
    group=$(id -gn)
    uid=$(id -u)
    home="$TEST_TMP/dry-home"
    fixture="$TEST_TMP/dry-os-release"
    mkdir -p "$home"
    write_os_release debian 'Debian Test' "$fixture"
    before=$(find "$home" -mindepth 1 -print | sort)
    output="$TEST_TMP/dry-run.out"

    if OS_RELEASE_FILE=$fixture \
        BOOTSTRAP_MACHINE=x86_64 \
        BOOTSTRAP_EUID=$uid \
        BOOTSTRAP_CURRENT_USER=$user \
        BOOTSTRAP_TARGET_GROUP=$group \
        BOOTSTRAP_PASSWD_RECORD="${user}:x:${uid}:$(id -g)::${home}:/bin/sh" \
        bash "$PROJECT_ROOT/install.sh" --dry-run --user "$user" >"$output" 2>&1; then
        pass 'installer dry run completes'
    else
        fail 'installer dry run completes'
    fi
    after=$(find "$home" -mindepth 1 -print | sort)
    assert_equal "$before" "$after" 'dry run does not modify target HOME'
    assert_success 'dry run reports no-state-change guarantee' grep -Fq 'no system state' "$output"
}

test_bootstrap_dry_run_no_changes() {
    local user uid gid home fixture fake_bin output stdin_output before after
    user=$(id -un)
    uid=$(id -u)
    gid=$(id -g)
    home="$TEST_TMP/bootstrap-dry-home"
    fixture="$TEST_TMP/bootstrap-os-release"
    fake_bin="$TEST_TMP/fake-bin"
    output="$TEST_TMP/bootstrap-dry-run.out"
    stdin_output="$TEST_TMP/bootstrap-stdin-dry-run.out"
    mkdir -p "$home" "$fake_bin"
    write_os_release ubuntu 'Ubuntu Test' "$fixture"
    cat >"$fake_bin/getent" <<'EOF'
#!/bin/sh
if [ "$1" = passwd ] && [ "$2" = "$FAKE_USERNAME" ]; then
    printf '%s\n' "$FAKE_PASSWD_RECORD"
    exit 0
fi
exit 2
EOF
    chmod +x "$fake_bin/getent"
    before=$(find "$home" -mindepth 1 -print | sort)

    if PATH="$fake_bin:$PATH" \
        FAKE_USERNAME=$user \
        FAKE_PASSWD_RECORD="${user}:x:${uid}:${gid}::${home}:/bin/sh" \
        BOOTSTRAP_UNAME_S=Linux \
        BOOTSTRAP_OS_RELEASE_FILE=$fixture \
        BOOTSTRAP_MACHINE=x86_64 \
        BOOTSTRAP_REPO_URL=https://github.com/GavinBS/linux-server-bootstrap.git \
        bash "$PROJECT_ROOT/bootstrap.sh" --dry-run --user "$user" --set-shell --ref v1.0.0 >"$output" 2>&1; then
        pass 'bootstrap dry run completes'
    else
        fail 'bootstrap dry run completes'
    fi
    after=$(find "$home" -mindepth 1 -print | sort)
    assert_equal "$before" "$after" 'bootstrap dry run does not modify target HOME'
    assert_success 'bootstrap dry run reports no-state-change guarantee' grep -Fq 'no system state' "$output"

    if PATH="$fake_bin:$PATH" \
        FAKE_USERNAME=$user \
        FAKE_PASSWD_RECORD="${user}:x:${uid}:${gid}::${home}:/bin/sh" \
        BOOTSTRAP_UNAME_S=Linux \
        BOOTSTRAP_OS_RELEASE_FILE=$fixture \
        BOOTSTRAP_MACHINE=x86_64 \
        bash -s -- --dry-run --user "$user" --set-shell --ref v1.0.0 <"$PROJECT_ROOT/bootstrap.sh" >"$stdin_output" 2>&1; then
        pass 'bootstrap accepts script input on standard input'
    else
        fail 'bootstrap accepts script input on standard input'
    fi
    assert_success 'standard-input bootstrap reports no-state-change guarantee' grep -Fq 'no system state' "$stdin_output"
}

test_default_shell_idempotency() {
    local user uid home
    user=$(id -un)
    uid=$(id -u)
    home="$TEST_TMP/shell-home"
    mkdir -p "$home"
    TARGET_USER=$user
    TARGET_HOME=$home
    TARGET_GROUP=$(id -gn)
    SYSTEM_ONLY=0
    DRY_RUN=0
    BOOTSTRAP_EUID=$uid
    BOOTSTRAP_CURRENT_USER=$user
    BOOTSTRAP_PASSWD_RECORD="${user}:x:${uid}:$(id -g)::${home}:/bin/zsh"
    find_zsh_path() { printf '/bin/zsh\n'; }
    assert_success 'default shell setup skips an already-correct shell' configure_default_shell
}

test_repository_detection() {
    local repo nonrepo expected remote seed install_dir stale user group home
    repo="$TEST_TMP/repository"
    nonrepo="$TEST_TMP/incomplete-repository"
    expected='https://github.com/GavinBS/linux-server-bootstrap.git'
    git init -q "$repo"
    git -C "$repo" remote add origin "$expected"
    mkdir -p "$nonrepo"

    # shellcheck source=../bootstrap.sh
    . "$PROJECT_ROOT/bootstrap.sh"
    assert_success 'existing expected Git repository is recognized' repository_matches "$repo" "$expected"
    assert_failure 'wrong Git remote is rejected' repository_matches "$repo" 'https://github.com/example/other.git'
    assert_failure 'interrupted non-Git checkout is treated as a conflict' repository_matches "$nonrepo" "$expected"
    assert_failure 'repository preparation refuses a conflicting path' repository_preparation_fails "$nonrepo"

    remote="$TEST_TMP/remote.git"
    seed="$TEST_TMP/seed"
    install_dir="$TEST_TMP/recovered-checkout"
    stale="${install_dir}.clone.stale"
    git init -q --bare "$remote"
    git init -q "$seed"
    git -C "$seed" config user.name 'Bootstrap Test'
    git -C "$seed" config user.email 'bootstrap-test@example.com'
    printf 'test\n' >"$seed/README"
    git -C "$seed" add README
    git -C "$seed" commit -qm 'test fixture'
    git -C "$seed" branch -M main
    git -C "$seed" remote add origin "$remote"
    git -C "$seed" push -q -u origin main

    user=$(id -un)
    group=$(id -gn)
    home="$TEST_TMP/repo-home"
    mkdir -p "$home" "$stale"
    REPO_URL=$remote
    REF=main
    SYSTEM_ONLY=0
    TARGET_USER=$user
    TARGET_GROUP=$group
    TARGET_HOME=$home
    BOOTSTRAP_EXPECTED_COMMIT=
    assert_success 'fresh staged repository checkout succeeds despite a stale staging directory' prepare_repository "$install_dir"
    assert_success 'checked-out repository contains fetched content' test -f "$install_dir/README"
    assert_success 'existing clean repository update is idempotent' prepare_repository "$install_dir"
}

test_distribution_detection
test_architecture_detection
test_package_mapping
test_user_resolution
test_dotfile_deployment
test_dry_run_no_changes
test_bootstrap_dry_run_no_changes
test_default_shell_idempotency
test_repository_detection

printf '\nTests: %d; Failures: %d\n' "$TESTS" "$FAILURES"
((FAILURES == 0))
