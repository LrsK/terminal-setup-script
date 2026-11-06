#!/usr/bin/env bash
# Installs a better zsh history/listing setup and a sensible tmux config.
#
#   zsh:  fzf (Ctrl+R fuzzy history menu), zsh-autosuggestions,
#         zsh-history-substring-search (Up/Down), big shared history,
#         eza listing aliases, starship prompt, better Tab completion
#         (git, plus kubectl/podman when installed), kubectl shortcuts
#   tools: k9s, fd, ripgrep, bat (fd and bat also power fzf's Ctrl+T and Alt+C)
#   font: JetBrains Mono Nerd Font
#   tmux: ~/.tmux.conf (existing one is backed up)
#
# Works on macOS (Homebrew) and Linux. On Linux it uses `pkg add` when available,
# and falls back to apt/dnf/pacman, upstream git or GitHub releases. Safe to re-run.
set -euo pipefail

ZSH_SNIPPET="$HOME/.config/zsh/shell-setup.zsh"
PLUGIN_DIR="$HOME/.local/share/zsh/plugins"
BIN_DIR="$HOME/.local/bin"
STAMP="$(date +%Y%m%d-%H%M%S)"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- install ---

install_macos() {
  if ! have brew; then
    warn "Homebrew is required. Install it from https://brew.sh and re-run this script."
    exit 1
  fi
  say "Installing packages with Homebrew"
  brew install zsh tmux fzf eza starship k9s fd ripgrep bat zsh-autosuggestions zsh-history-substring-search
  brew install --cask font-jetbrains-mono-nerd-font
}

sudo_cmd() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# Where zsh plugins can live: Nix profiles, distro packages, git clones.
# Keep in sync with _load_plugin in the zsh config below.
PLUGIN_SEARCH=(
  "$HOME/.nix-profile/share"
  "$HOME/.local/state/nix/profiles/profile/share"
  "/etc/profiles/per-user/${USER:-$(id -un)}/share"
  /nix/var/nix/profiles/default/share
  /run/current-system/sw/share
  /usr/share/zsh/plugins
  /usr/share
  "$PLUGIN_DIR"
)
# So tools installed by Nix or into ~/.local/bin are seen right after install
PATH="$HOME/.fzf/bin:$BIN_DIR:$HOME/.nix-profile/bin:$HOME/.local/state/nix/profiles/profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

have_plugin() {
  local d
  for d in "${PLUGIN_SEARCH[@]}"; do
    [ -r "$d/$1/$1.zsh" ] && return 0
  done
  return 1
}

# `pkg add` is a local tool that installs from apt or nixpkgs. Never fatal:
# every result is checked afterwards and falls back to another method.
pkg_add() {
  have pkg || return 1
  say "pkg add $1"
  pkg add "$1" || { warn "pkg add $1 failed"; return 1; }
}

# ensure_cmd <command>: install with pkg if missing; succeeds if it's now on PATH
ensure_cmd() {
  have "$1" && return 0
  pkg_add "$1" || true
  hash -r
  have "$1"
}

distro_install() {
  if have apt-get; then
    sudo_cmd apt-get update -qq
    sudo_cmd apt-get install -y -qq "$@"
  elif have dnf; then
    sudo_cmd dnf install -y -q "$@"
  elif have pacman; then
    sudo_cmd pacman -Sy --noconfirm --needed "$@"
  else
    warn "Could not install: $*. No pkg, apt, dnf or pacman available; install them yourself and re-run."
    exit 1
  fi
}

# `fzf --zsh` needs 0.48+, and distro packages are often older
fzf_new_enough() {
  have fzf || return 1
  printf '0.48\n%s\n' "$(fzf --version | cut -d' ' -f1)" | sort -V -C
}

install_linux() {
  have pkg && say "Using pkg for installs, with fallbacks if it can't provide something"

  say "Base tools: zsh tmux git curl vim"
  local missing=() t
  for t in zsh tmux git curl vim; do
    ensure_cmd "$t" || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    say "Installing with the distro package manager: ${missing[*]}"
    distro_install "${missing[@]}"
  fi

  if ! { ensure_cmd fzf && fzf_new_enough; }; then
    say "Installing fzf from upstream (missing or older than 0.48)"
    if [ -d "$HOME/.fzf/.git" ]; then
      git -C "$HOME/.fzf" pull -q --ff-only
    else
      git clone -q --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
    fi
    "$HOME/.fzf/install" --bin >/dev/null
    hash -r
  fi

  local name
  for name in zsh-autosuggestions zsh-history-substring-search; do
    have_plugin "$name" && continue
    pkg_add "$name" || true
    have_plugin "$name" && continue
    say "Cloning $name from GitHub"
    mkdir -p "$PLUGIN_DIR"
    rm -rf "${PLUGIN_DIR:?}/$name"
    git clone -q --depth 1 "https://github.com/zsh-users/$name.git" "$PLUGIN_DIR/$name"
  done

  ensure_cmd eza      && eza_ok=1      || eza_ok=0
  ensure_cmd starship && starship_ok=1 || starship_ok=0
  [ "$eza_ok$starship_ok" = 11 ] && return 0

  case "$(uname -m)" in
    x86_64)        arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) warn "No eza/starship binaries for $(uname -m); skipping them"; return ;;
  esac
  mkdir -p "$BIN_DIR"

  if [ "$eza_ok" = 0 ]; then
    say "Installing eza from GitHub releases"
    curl -fsSL "https://github.com/eza-community/eza/releases/latest/download/eza_${arch}-unknown-linux-gnu.tar.gz" \
      | tar -xz -C "$BIN_DIR"
    chmod +x "$BIN_DIR/eza"
  fi

  if [ "$starship_ok" = 0 ]; then
    say "Installing starship from GitHub releases"
    curl -fsSL "https://github.com/starship/starship/releases/latest/download/starship-${arch}-unknown-linux-musl.tar.gz" \
      | tar -xz -C "$BIN_DIR"
    chmod +x "$BIN_DIR/starship"
  fi
}

# ensure_tool <command> <distro's other name for it, or ""> <packages to try...>
# Debian-based distros ship fd as fdfind and bat as batcat, so those get a symlink.
ensure_tool() {
  local cmd=$1 alt=$2 name
  shift 2
  for name in "$@"; do
    { have "$cmd" || have "$alt"; } && break
    pkg_add "$name" || true
    hash -r
  done
  if ! have "$cmd" && have "$alt"; then
    mkdir -p "$BIN_DIR"
    ln -sf "$(command -v "$alt")" "$BIN_DIR/$cmd"
    hash -r
  fi
  have "$cmd"
}

# github_release <command> <owner/repo> <asset name, {tag} becomes the release tag>
github_release() {
  local cmd=$1 repo=$2 asset=$3 tag tmp
  say "Installing $cmd from GitHub releases"
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")
  tag=${tag##*/}
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/$repo/releases/download/$tag/${asset//\{tag\}/$tag}" | tar -xz -C "$tmp"
  mkdir -p "$BIN_DIR"
  find "$tmp" -type f -name "$cmd" -exec install -m 755 {} "$BIN_DIR/$cmd" \;
  rm -rf "$tmp"
  hash -r
  have "$cmd"
}

install_cli_tools_linux() {
  local triple k9s_arch
  case "$(uname -m)" in
    x86_64)        triple=x86_64-unknown-linux-musl;  k9s_arch=amd64 ;;
    aarch64|arm64) triple=aarch64-unknown-linux-gnu;  k9s_arch=arm64 ;;
    *) triple=""; k9s_arch="" ;;
  esac

  fallback() {
    if [ -n "$triple" ]; then
      github_release "$@" || warn "Could not install $1"
    else
      warn "No $1 binary for $(uname -m); skipping it"
    fi
  }

  ensure_tool rg  ""     ripgrep      || fallback rg  BurntSushi/ripgrep "ripgrep-{tag}-$triple.tar.gz"
  ensure_tool fd  fdfind fd fd-find   || fallback fd  sharkdp/fd         "fd-{tag}-$triple.tar.gz"
  ensure_tool bat batcat bat          || fallback bat sharkdp/bat        "bat-{tag}-$triple.tar.gz"
  ensure_tool k9s ""     k9s          || fallback k9s derailed/k9s       "k9s_Linux_$k9s_arch.tar.gz"
}

FONT_DIR="$HOME/.local/share/fonts"

have_nerd_font() {
  if have fc-list; then
    fc-list : family 2>/dev/null | grep -qi 'JetBrainsMono Nerd Font'
  else
    find -L "$FONT_DIR" "$HOME/.nix-profile/share/fonts" /usr/share/fonts /usr/local/share/fonts \
      -iname 'JetBrainsMonoNerdFont*' -print -quit 2>/dev/null | grep -q .
  fi
}

install_nerd_font_linux() {
  # fc-cache/fc-list make the font visible to apps; fine to lack on a headless box
  have fc-cache || pkg_add fontconfig || true
  hash -r

  if ! have_nerd_font; then
    pkg_add nerd-fonts.jetbrains-mono || true
    # Nix puts fonts in its profile, which fontconfig doesn't search by default
    if [ -d "$HOME/.nix-profile/share/fonts" ] && [ ! -e "$FONT_DIR/nix-profile" ]; then
      mkdir -p "$FONT_DIR"
      ln -s "$HOME/.nix-profile/share/fonts" "$FONT_DIR/nix-profile"
    fi
    have fc-cache && fc-cache -f "$FONT_DIR" >/dev/null 2>&1
  fi

  if ! have_nerd_font; then
    say "Installing JetBrains Mono Nerd Font from GitHub releases"
    if ! have xz; then   # needed to unpack the .tar.xz
      pkg_add xz || pkg_add xz-utils || true
      hash -r
      if ! have xz; then
        if have apt-get; then distro_install xz-utils; else distro_install xz; fi
      fi
    fi
    mkdir -p "$FONT_DIR/JetBrainsMonoNerdFont"
    curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz \
      | tar -xJ -C "$FONT_DIR/JetBrainsMonoNerdFont"
    have fc-cache && fc-cache -f "$FONT_DIR" >/dev/null 2>&1
  fi

  have_nerd_font && say "JetBrains Mono Nerd Font is installed" \
    || warn "JetBrains Mono Nerd Font could not be verified"
}

# ------------------------------------------------------------- zsh config ---

write_zsh_config() {
  say "Writing $ZSH_SNIPPET"
  mkdir -p "$(dirname "$ZSH_SNIPPET")"
  cat > "$ZSH_SNIPPET" <<'ZSH'
# Managed by setup-shell.sh -- re-running the script overwrites this file.

path=(~/.fzf/bin ~/.local/bin $path)
typeset -U path

# --- History: big, shared, deduplicated ---
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt EXTENDED_HISTORY        # save timestamps
setopt SHARE_HISTORY           # share history live across open shells
setopt HIST_IGNORE_ALL_DUPS    # drop older copies of a repeated command
setopt HIST_FIND_NO_DUPS
setopt HIST_IGNORE_SPACE       # a leading space keeps a command out of history
setopt HIST_REDUCE_BLANKS

# --- Editor ---
export EDITOR=vim VISUAL=vim
bindkey -e                     # zsh would otherwise switch the command line to vi mode

# --- Home/End/Delete etc.: terminals and tmux send different codes, so bind them all ---
# (distro zshrc files bind only the terminfo code, and an unbound key prints a stray ~)
() {
  local km seq widget seqs
  local -A keys=(
    beginning-of-line    '^[[H ^[OH ^[[1~ ^[[7~'   # Home
    end-of-line          '^[[F ^[OF ^[[4~ ^[[8~'   # End
    delete-char          '^[[3~'                   # Delete
    overwrite-mode       '^[[2~'                   # Insert
    beginning-of-buffer-or-history '^[[5~'         # Page Up
    end-of-buffer-or-history       '^[[6~'         # Page Down
    backward-word        '^[[1;5D ^[[1;3D ^[^[[D'  # Ctrl/Alt+Left
    forward-word         '^[[1;5C ^[[1;3C ^[^[[C'  # Ctrl/Alt+Right
    kill-word            '^[[3;5~ ^[[3;3~'         # Ctrl/Alt+Delete
    reverse-menu-complete '^[[Z'                   # Shift+Tab
  )
  for km in emacs viins; do
    for widget seqs in ${(kv)keys}; do
      for seq in ${=seqs}; do bindkey -M $km "$seq" $widget; done
    done
  done
}

# --- Tab completion (git's comes built into zsh) ---
(( ${+functions[compdef]} )) || { autoload -Uz compinit && compinit; }
zstyle ':completion:*' menu select                         # arrow-key menu on the second Tab
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'  # case-insensitive, then partial words
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ${XDG_CACHE_HOME:-$HOME/.cache}/zsh/compcache

# Sources `<tool> completion zsh`, cached so shells start fast. Regenerated when
# the binary changes (the resolved path is recorded, since Nix store files are all dated 1970).
_cached_completion() {
  local bin=${commands[$1]} cache=${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completion-$1.zsh first
  [[ -n $bin ]] || return 1
  local real=${bin:A}
  [[ -s $cache ]] && read -r first < $cache
  if [[ $first != "# $real" || $real -nt $cache ]]; then
    mkdir -p ${cache:h}
    { print -r -- "# $real"; $1 completion zsh 2>/dev/null } >| $cache.tmp && mv -f $cache.tmp $cache
  fi
  source $cache
}
_cached_completion kubectl
_cached_completion podman
_cached_completion k9s
unfunction _cached_completion

# Finds a plugin in Homebrew, distro or git-clone locations
_load_plugin() {
  local d
  for d in /opt/homebrew/share /usr/local/share \
           ~/.nix-profile/share ~/.local/state/nix/profiles/profile/share \
           /etc/profiles/per-user/$USERNAME/share /nix/var/nix/profiles/default/share \
           /run/current-system/sw/share /usr/share/zsh/plugins /usr/share ~/.local/share/zsh/plugins; do
    [[ -r $d/$1/$1.zsh ]] && { source $d/$1/$1.zsh; return 0; }
  done
  return 1
}

# --- Ctrl+R: fuzzy menu over history (fzf), seeded with what's typed ---
# Space-separated words match in any order; 'exact, ^prefix, suffix$, !negate
if (( $+commands[fzf] )); then
  export FZF_CTRL_R_OPTS="--height=40% --layout=reverse --info=inline \
    --preview='echo {2..}' --preview-window=down:3:wrap:hidden \
    --bind='?:toggle-preview' --header='Enter: run-ready  |  ?: show full command'"
  if (( $+commands[fd] )); then  # faster file search that skips gitignored files
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
    export FZF_CTRL_T_COMMAND=$FZF_DEFAULT_COMMAND
    export FZF_ALT_C_COMMAND='fd --type d --hidden --exclude .git'
  fi
  if (( $+commands[bat] )); then # highlighted file preview in Ctrl+T
    export FZF_CTRL_T_OPTS="--preview='bat --color=always --style=numbers --line-range=:200 {}'"
  fi
  source <(fzf --zsh)          # also gives Ctrl+T (files) and Alt+C (cd)
fi

# --- Inline ghost-text suggestion from history (accept with → or End) ---
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
# Fixed gray: color 8 follows the theme, and 8-color TERMs (xterm, screen) drop it entirely
zmodload zsh/terminfo
if (( ${terminfo[colors]:-0} >= 256 )); then
  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'
else
  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=cyan'
fi
_load_plugin zsh-autosuggestions

# --- Up/Down: cycle history entries containing what's typed (anywhere) ---
if _load_plugin zsh-history-substring-search; then
  HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE=1
  HISTORY_SUBSTRING_SEARCH_FUZZY=1   # words match in order, gaps allowed
  # The plugin's stand-in for zsh-syntax-highlighting clears every highlight on each
  # keypress, which removes the suggestion's color; keep that one highlight.
  _zsh_highlight() {
    [[ $KEYS == [[:print:]] ]] || return 0
    if [[ -n $_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT ]]; then
      region_highlight=( "${(@M)region_highlight:#${(b)_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT}}" )
    else
      region_highlight=()
    fi
    return 0
  }
  bindkey '^[[A' history-substring-search-up      # Up
  bindkey '^[OA' history-substring-search-up      # Up (application mode)
  bindkey '^[[B' history-substring-search-down    # Down
  bindkey '^[OB' history-substring-search-down    # Down (application mode)
fi
unfunction _load_plugin

# --- Directory listing (eza) ---
if (( $+commands[eza] )); then
  alias ls='eza --icons=auto --group-directories-first'
  alias ll='eza --icons=auto -l --git --group-directories-first --time-style=relative'   # long view with git status
  alias la='ll -a'                                                            # same, including hidden files
  alias lt='eza --icons=auto --tree --level=2 --git-ignore'                                # tree, 2 levels, skips gitignored files
  alias lS='eza --icons=auto -l --sort=size --reverse'                                     # biggest files first
fi

# --- kubectl shortcuts (Tab completion works through all of these) ---
if (( $+commands[kubectl] )); then
  alias k='kubectl'
  alias kg='kubectl get'
  alias kgp='kubectl get pods'
  alias kgpw='kubectl get pods -o wide'
  alias kgs='kubectl get svc'
  alias kgd='kubectl get deploy'
  alias kd='kubectl describe'
  alias kl='kubectl logs -f --tail=100'
  alias kex='kubectl exec -it'
  alias kaf='kubectl apply -f'
  alias kdel='kubectl delete'

  # kctx [name]: switch context; without a name, pick one with fzf
  kctx() {
    local c=${1:-$(kubectl config get-contexts -o name | fzf --height=40% --layout=reverse --prompt='context> ')}
    [[ -n $c ]] && kubectl config use-context "$c"
  }
  # kns [name]: switch the current context's namespace; without a name, pick one with fzf
  kns() {
    local n=${1:-$(kubectl get namespaces -o name | cut -d/ -f2 | fzf --height=40% --layout=reverse --prompt='namespace> ')}
    [[ -n $n ]] && kubectl config set-context --current --namespace="$n"
  }
  _kctx() { compadd -- ${(f)"$(kubectl config get-contexts -o name 2>/dev/null)"} }
  _kns()  { compadd -- ${${(f)"$(kubectl get namespaces -o name 2>/dev/null)"}#namespace/} }
  compdef _kctx kctx
  compdef _kns kns
fi

# --- Prompt (starship; customise in ~/.config/starship.toml) ---
(( $+commands[starship] )) && eval "$(starship init zsh)"
ZSH

  local line='[[ -r ~/.config/zsh/shell-setup.zsh ]] && source ~/.config/zsh/shell-setup.zsh'
  if ! grep -qF "$line" "$HOME/.zshrc" 2>/dev/null; then
    say "Adding source line to ~/.zshrc"
    [ -f "$HOME/.zshrc" ] && cp "$HOME/.zshrc" "$HOME/.zshrc.bak-$STAMP"
    printf '\n# Shell setup (history search, eza aliases)\n%s\n' "$line" >> "$HOME/.zshrc"
  fi
}

# ------------------------------------------------------------ tmux config ---

write_tmux_config() {
  if [ -f "$HOME/.tmux.conf" ] && ! grep -q 'Managed by setup-shell.sh' "$HOME/.tmux.conf"; then
    say "Backing up existing ~/.tmux.conf to ~/.tmux.conf.bak-$STAMP"
    cp "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak-$STAMP"
  fi
  say "Writing ~/.tmux.conf"
  cat > "$HOME/.tmux.conf" <<'TMUX'
# Managed by setup-shell.sh -- re-running the script overwrites this file.
# Prefix is the default Ctrl+b.

# --- Terminal & behaviour ---
# macOS's system ncurses lacks tmux-256color, so fall back where it's missing
if-shell 'infocmp tmux-256color >/dev/null 2>&1' \
  'set -g default-terminal "tmux-256color"' \
  'set -g default-terminal "screen-256color"'
set -as terminal-features ',*:RGB'   # true colour
set -g  mouse on                     # click panes, drag borders, scroll
set -g  history-limit 50000
set -sg escape-time 10               # no lag after Esc in vim
set -g  focus-events on
set -g  base-index 1                 # windows start at 1 (matches keyboard)
setw -g pane-base-index 1
set -g  renumber-windows on          # no gaps after closing a window
set -g  set-titles on
set -g  display-time 2000
set -s  set-clipboard on             # copy to system clipboard via OSC 52

# --- Keys ---
bind r source-file ~/.tmux.conf \; display 'tmux.conf reloaded'

# Splits and new windows open in the current directory; | and - are easier to remember
bind |   split-window -h -c '#{pane_current_path}'
bind -   split-window -v -c '#{pane_current_path}'
bind %   split-window -h -c '#{pane_current_path}'
bind '"' split-window -v -c '#{pane_current_path}'
bind c   new-window      -c '#{pane_current_path}'

# Move between panes: Alt+arrows (no prefix) or prefix + h/j/k/l
bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Resize with prefix + H/J/K/L (repeatable)
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# Copy mode (prefix + [): vi keys, v to select, y to copy
setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-selection-and-cancel
if-shell 'command -v pbcopy >/dev/null' \
  "bind -T copy-mode-vi y send -X copy-pipe-and-cancel pbcopy"

# --- Look ---
set -g status-style 'bg=default,fg=colour245'
set -g status-left '#[fg=colour39,bold]#S #[default]'
set -g status-left-length 30
set -g status-right '#h  %H:%M'
setw -g window-status-format ' #I:#W '
setw -g window-status-current-format ' #I:#W '
setw -g window-status-current-style 'fg=colour39,bold'
set -g pane-border-style 'fg=colour238'
set -g pane-active-border-style 'fg=colour39'
TMUX
}

# ------------------------------------------------------------------- main ---

case "$(uname -s)" in
  Darwin) install_macos ;;
  Linux)  install_linux; install_cli_tools_linux; install_nerd_font_linux ;;
  *) warn "Unsupported OS: $(uname -s)"; exit 1 ;;
esac

write_zsh_config
write_tmux_config

say "Done. Open a new terminal (or run: exec zsh)."
if [ "$(basename "${SHELL:-}")" != zsh ]; then
  warn "Your login shell is ${SHELL:-unknown}. To make zsh the default, run: chsh -s \"$(command -v zsh)\""
fi
