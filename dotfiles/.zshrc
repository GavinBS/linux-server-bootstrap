# Managed by linux-server-bootstrap.
# Keep this file portable: it is used only on remote Linux servers.

typeset -U path PATH
path=("$HOME/.local/bin" $path)
export PATH

export EDITOR=nvim
export VISUAL=nvim
export PAGER=less
export LESS='-FRX'

# History is stored under XDG state rather than directly in $HOME.
_zsh_state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/zsh
if [[ ! -d $_zsh_state_dir ]]; then
    mkdir -p -- "$_zsh_state_dir"
fi
HISTFILE=$_zsh_state_dir/history
HISTSIZE=10000
SAVEHIST=10000
setopt append_history
setopt share_history
setopt hist_ignore_dups
setopt hist_ignore_space
setopt extended_history

autoload -Uz compinit
_zsh_cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/zsh
if [[ ! -d $_zsh_cache_dir ]]; then
    mkdir -p -- "$_zsh_cache_dir"
fi
compinit -d "$_zsh_cache_dir/zcompdump-$ZSH_VERSION"

bindkey -e
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line

if command -v fzf >/dev/null 2>&1; then
    for _fzf_script in \
        /usr/share/doc/fzf/examples/key-bindings.zsh \
        /usr/share/fzf/key-bindings.zsh; do
        if [[ -r $_fzf_script ]]; then
            source "$_fzf_script"
            break
        fi
    done
fi

if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
fi

if command -v eza >/dev/null 2>&1; then
    alias ls='eza --group-directories-first'
    alias ll='eza -lah --group-directories-first'
else
    alias ls='ls --color=auto'
    alias ll='ls -lah'
fi

if command -v bat >/dev/null 2>&1; then
    alias cat='bat --paging=never'
elif command -v batcat >/dev/null 2>&1; then
    alias cat='batcat --paging=never'
fi

if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    alias fd='fdfind'
fi

alias grep='grep --color=auto'
alias v='nvim'
alias g='git'

PROMPT='%F{cyan}%n@%m%f:%F{blue}%~%f %# '

unset _zsh_state_dir _zsh_cache_dir _fzf_script
