# Linux Server Bootstrap

A lightweight bootstrap tool for setting up my terminal environment on freshly installed Linux servers.

The project uses Bash, distribution repositories, and plain file copies. It does not require Nix, Home Manager, Ansible, Chezmoi, Stow, or another configuration-management framework. Its scope is intentionally limited to command-line tools and terminal configuration.

## Supported systems

| Distribution | Package manager | Status |
|---|---|---|
| Debian | `apt-get` | Supported |
| Ubuntu | `apt-get` | Supported |
| Arch Linux | `pacman` | Supported |
| Fedora | `dnf` | Supported |

Supported CPU architectures are `x86_64`/`amd64` and `aarch64`/`arm64`. Packages come from the configured distribution repositories, so no architecture-specific binary download is used by default. Other distributions and architectures stop with an explicit error.

## Installed tools

The installer checks commands before asking the package manager to install anything.

| Tool | Debian/Ubuntu package | Arch package | Fedora package |
|---|---|---|---|
| Zsh | `zsh` | `zsh` | `zsh` |
| Neovim | `neovim` | `neovim` | `neovim` |
| Git | `git` | `git` | `git` |
| curl | `curl` | `curl` | `curl` |
| fzf | `fzf` | `fzf` | `fzf` |
| zoxide | `zoxide` | `zoxide` | `zoxide` |
| ripgrep | `ripgrep` | `ripgrep` | `ripgrep` |
| fd | `fd-find` | `fd` | `fd-find` |
| bat | `bat` | `bat` | `bat` |
| eza | `eza` | `eza` | `eza` |
| tmux | `tmux` | `tmux` | `tmux` |

`fd`/`fdfind` and `bat`/`batcat` command-name differences are handled by both verification and the Zsh configuration. If a non-critical package is unavailable in the enabled official repositories, installation continues and the final summary reports the failure. Git, curl, and Zsh are critical.

Debian and Ubuntu run `apt-get update` only when at least one requested tool is missing. The project never runs `apt-get upgrade` or `apt-get full-upgrade`. Fedora uses `dnf install` and never runs `dnf upgrade`.

Arch deliberately never runs `pacman -Sy`, which could create a partial upgrade. It also does not run `pacman -Syu` automatically. It installs with the existing sync database using `pacman -S --needed`; when no sync database exists or repository state is too old to install a package, review and run a full `pacman -Syu` yourself, then rerun the bootstrap.

## Before publishing your fork

Change this line near the top of `bootstrap.sh`:

```bash
DEFAULT_REPO_URL='https://github.com/USER/linux-server-bootstrap.git'
```

Replace `USER` with the GitHub account or organization that will host the public repository. Alternatively, leave the file unchanged and set `BOOTSTRAP_REPO_URL` when running it.

The repository contains no required secrets, tokens, hostnames, IP addresses, or private keys. Do not add credentials to the repository, its URL, dotfiles, local overrides, or Git history.

## Quick start

After replacing `USER`, download and inspect the bootstrap before executing it:

```bash
curl -fsSLo bootstrap.sh \
  https://raw.githubusercontent.com/USER/linux-server-bootstrap/main/bootstrap.sh

less bootstrap.sh
bash bootstrap.sh
```

The bootstrap installs Git if necessary, checks out the repository at `~/.local/share/linux-server-bootstrap`, and starts `install.sh`. It asks for `sudo` only for package and system-level changes. Do not use `sudo bash bootstrap.sh`; run it as the user whose terminal environment should be configured.

## Safe, version-pinned installation

`main` is convenient but mutable. For a server, prefer a reviewed tag or full commit ID:

```bash
REF=v1.0.0

curl -fsSLo bootstrap.sh \
  "https://raw.githubusercontent.com/USER/linux-server-bootstrap/${REF}/bootstrap.sh"

sha256sum bootstrap.sh
less bootstrap.sh
bash bootstrap.sh --ref "$REF"
```

Compare the printed SHA-256 digest with a checksum obtained through a separate trusted channel before execution. To make the repository checkout itself require one exact commit, set the full commit ID:

```bash
BOOTSTRAP_EXPECTED_COMMIT=0123456789abcdef0123456789abcdef01234567 \
  bash bootstrap.sh --ref 0123456789abcdef0123456789abcdef01234567
```

The example commit is a placeholder. Use a real, reviewed full commit from your repository. A pinned ref protects against unintended version drift; a separately verified SHA-256 protects the downloaded bootstrap file. Neither `curl | bash` nor downloading from `main` is inherently safe, so the recommended workflow downloads, verifies, reviews, and then executes.

## Usage

```text
Usage: bash bootstrap.sh [options]

Options:
  --dry-run       Show planned changes without modifying the system
  --user USER     Deploy configuration for USER (required for root user setup)
  --set-shell     Set zsh as the target user's default shell
  --ref REF       Git tag, branch, or full commit to install (default: main)
  -h, --help      Show help
```

Normal user installation:

```bash
bash bootstrap.sh
```

Normal user installation with Zsh as the default shell:

```bash
bash bootstrap.sh --set-shell
```

Root login targeting an existing normal user:

```bash
bash bootstrap.sh --user exampleuser --set-shell
```

Root without `--user` installs system packages only. It does not guess a user, deploy to `/root`, or change root's shell:

```bash
bash bootstrap.sh
```

Pinned release:

```bash
bash bootstrap.sh --ref v1.0.0
```

Dry run:

```bash
bash bootstrap.sh --dry-run --user exampleuser --set-shell --ref v1.0.0
```

Dry Run detects the distribution, architecture, user, package mapping, repository location, configuration destinations, and requested shell change. It does not validate sudo, update package indexes, install packages, clone or fetch Git, create files, edit `/etc/shells`, or run `chsh`.

If the published repository URL was not edited into `bootstrap.sh`, provide it without putting credentials in the URL:

```bash
BOOTSTRAP_REPO_URL=https://github.com/USER/linux-server-bootstrap.git \
  bash bootstrap.sh --ref v1.0.0
```

## Root and user behavior

User homes are resolved from the system account database with `getent passwd`; the scripts never assume `/home/USER`. A non-root process may configure only its current user. Root must pass `--user` to deploy personal configuration, and the target must not be root.

Directories and files deployed for a target user are assigned to that user's primary group and user account. Privilege is limited to package installation, adding a validated Zsh path to `/etc/shells`, changing the selected user's login shell, and creating a system-only checkout under `/var/lib`.

## Default shell

Changing the login shell is opt-in through `--set-shell`. The installer:

1. verifies that `zsh` exists;
2. obtains its actual command path;
3. checks `/etc/shells` and appends the path only if absent;
4. reads the current login shell from the account database;
5. skips `chsh` if the shell is already correct; and
6. reports failure without replacing or damaging the existing shell.

Log out and back in after a successful shell change.

## Dotfiles and backups

The repository copies, rather than symlinks, these files:

```text
~/.zshrc
~/.config/nvim/init.lua
~/.config/tmux/tmux.conf
~/.tmux.conf
```

Copying keeps the installed environment independent of the checkout directory. The small `~/.tmux.conf` compatibility file loads the XDG configuration for tmux versions that do not discover it automatically.

When a destination differs and has never been managed by this project, it is copied once to `DESTINATION.bootstrap-backup`. The installer records hashes under `~/.local/state/linux-server-bootstrap/`:

- an unchanged managed file can be upgraded when the repository changes;
- a file already identical to the source is skipped;
- a user modification after deployment is never silently overwritten; and
- the one-time backup is never numbered, multiplied, or replaced.

If a user-modified destination conflicts while its backup already exists, preserve or merge the change manually and rerun the installer.

## Idempotency and recovery

Repeated runs check installed commands, compare configuration contents, reuse the repository only when its `origin` matches, and skip an already-correct login shell. Package indexes are refreshed only when an installation is required. `/etc/shells` is never appended twice.

Repository clones are assembled in a uniquely named staging directory and moved into place only after a successful fetch and checkout. A failed fetch leaves that staging directory for inspection but never deletes or overwrites an existing path. An existing non-Git directory, wrong remote, or dirty checkout stops with an explicit error. A later rerun uses a fresh staging directory.

The installer exits with status `2` when non-critical items failed, after completing and printing the summary. Critical failures exit with status `1` immediately.

## Updating the bootstrap repository

Rerun the downloaded bootstrap with the desired reviewed ref:

```bash
bash bootstrap.sh --ref v1.1.0
```

The existing checkout must have the expected `origin` and a clean worktree. The bootstrap fetches only the requested ref and checks it out detached. It never deletes the checkout, resets local changes, upgrades the operating system, or guesses a different remote.

## Directory structure

```text
linux-server-bootstrap/
├── bootstrap.sh                 # Standalone remote entry point
├── install.sh                   # Installation orchestration and summary
├── lib/
│   ├── common.sh                # Logging and portable helpers
│   ├── distro.sh                # Distribution and CPU detection
│   ├── dotfiles.sh              # Copy, backup, state, and conflict handling
│   ├── packages.sh              # Logical tool mapping and package operations
│   └── users.sh                 # User, HOME, ownership, sudo, and chsh logic
├── dotfiles/
│   ├── .zshrc                   # Small framework-free Zsh configuration
│   ├── .tmux.conf               # tmux compatibility entry point
│   └── .config/
│       ├── nvim/init.lua        # Plugin-free, version-tolerant Neovim setup
│       └── tmux/tmux.conf       # Plugin-free tmux configuration
├── tests/
│   ├── test.sh                  # Host-safe functional tests
│   └── container-smoke.sh       # Optional four-distribution dry-run smoke test
├── .gitignore
├── LICENSE
└── README.md
```

## Testing

Run the host-safe test suite:

```bash
bash tests/test.sh
```

Run ShellCheck when installed:

```bash
shellcheck bootstrap.sh install.sh lib/*.sh tests/*.sh
zsh -n dotfiles/.zshrc
```

Run read-only dry-run smoke tests in fresh distribution containers (images may be downloaded):

```bash
bash tests/container-smoke.sh
```

These container tests validate syntax, distribution detection, architecture detection, root system-only behavior, and Dry Run. They do not install packages or test `chsh`. Before relying on a new release in production, verify a full installation on disposable Debian, Ubuntu, Arch, and Fedora systems for each architecture you use.

## Troubleshooting

**A package is unavailable**

Confirm that the distribution's normal official repositories are enabled. Optional tools remain in the final failure summary. No third-party installer or random `curl | bash` fallback is used.

**Arch reports no sync database or installation fails**

Review pending system changes and run `pacman -Syu` yourself. Do not run `pacman -Sy package`. Rerun the bootstrap afterward.

**The checkout already exists**

The path must be a clean Git repository whose `origin` is the configured URL. Commit or move deliberate local work yourself. For a non-Git conflict, choose how to preserve it; the bootstrap will not remove it.

**A dotfile conflict is reported**

Compare the destination, its `.bootstrap-backup`, and the repository version. Merge manually, then either make the destination equal to the desired managed file or remove only the obsolete per-file state entry after review.

**The default shell did not change**

Review the displayed `chsh` or `/etc/shells` error. Package installation and dotfile deployment remain usable. Rerun with `--set-shell` after fixing the underlying permission or account policy.

## Security notes

- Use an HTTPS public GitHub URL without embedded credentials.
- Prefer a reviewed tag or full commit and verify the downloaded bootstrap checksum through a separate trusted channel.
- Review changes before running with sudo access.
- The project never logs passwords, tokens, private keys, or sudo credentials.
- Package installation uses only configured distribution repositories by default.
- No full operating-system upgrade, firewall change, service deployment, Docker setup, database setup, VPN setup, or data restoration is performed.
- `.gitignore` excludes common secret, environment, local override, log, temporary, test artifact, and editor files; it is not a substitute for reviewing every commit and the complete Git history before publishing.
