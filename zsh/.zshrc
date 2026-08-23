#!/usr/bin/env zsh
# Interactive shell configuration.

# Non-login interactive shells never run .zprofile, so pick it up here. The
# flag it sets means a login shell does not run it twice.
if [[ -z ${_DOTFILES_ZPROFILE_LOADED:-} && -r $HOME/.zprofile ]]; then
    source "$HOME/.zprofile"
fi

export CLICOLOR=1
export ZSH_CACHE_DIR=$HOME/.zsh/cache
[[ -d $ZSH_CACHE_DIR ]] || mkdir -p "$ZSH_CACHE_DIR"

# History {{{
# =======
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000000
SAVEHIST=10000000

setopt BANG_HIST                 # Treat the '!' character specially during expansion.
setopt EXTENDED_HISTORY          # Write the history file in the ":start:elapsed;command" format.
setopt INC_APPEND_HISTORY        # Write to the history file immediately, not when the shell exits.
setopt NO_SHARE_HISTORY          # Keep each session's history to itself.
setopt HIST_EXPIRE_DUPS_FIRST    # Expire duplicate entries first when trimming history.
setopt HIST_IGNORE_DUPS          # Don't record an entry that was just recorded again.
setopt HIST_IGNORE_ALL_DUPS      # Delete old recorded entry if new entry is a duplicate.
setopt HIST_FIND_NO_DUPS         # Do not display a line previously found.
setopt HIST_IGNORE_SPACE         # Don't record an entry starting with a space.
setopt HIST_SAVE_NO_DUPS         # Don't write duplicate entries in the history file.
setopt HIST_REDUCE_BLANKS        # Remove superfluous blanks before recording entry.
setopt HIST_VERIFY               # Don't execute immediately upon history expansion.
setopt INTERACTIVE_COMMENTS      # Allow comments in an interactive shell
# }}}

# Completion {{{
# ==========
zmodload -i zsh/complist

setopt COMPLETE_ALIASES   # Prevent aliases from being substituted before completion is attempted.
setopt COMPLETE_IN_WORD   # Attempt to start completion from both ends of a word.
setopt GLOB_COMPLETE      # Don't insert anything resulting from a glob pattern, show completion menu.
setopt NO_LIST_BEEP       # Don't beep on an ambiguous completion.
setopt LIST_PACKED        # Try to make the completion list smaller by drawing smaller columns.
setopt MENU_COMPLETE      # Instead of listing possibilities, select the first match immediately.
setopt AUTO_MENU          # Show completion menu on successive tab press

zstyle ':completion:*' completer _oldlist _expand _complete _match _ignored _approximate
# Match dircolors with completion schema.
zstyle ':completion:*' list-colors ${(s#:#)LS_COLORS}
# case insensitive (all), partial-word and substring completion
if [[ "$CASE_SENSITIVE" = true ]]; then
  zstyle ':completion:*' matcher-list 'r:|=*' 'l:|=* r:|=*'
else
  if [[ "$HYPHEN_INSENSITIVE" = true ]]; then
    zstyle ':completion:*' matcher-list 'm:{[:lower:][:upper:]-_}={[:upper:][:lower:]_-}' 'r:|=*' 'l:|=* r:|=*'
  else
    zstyle ':completion:*' matcher-list 'm:{[:lower:][:upper:]}={[:upper:][:lower:]}' 'r:|=*' 'l:|=* r:|=*'
  fi
fi
unset CASE_SENSITIVE HYPHEN_INSENSITIVE
# pasting with tabs doesn't perform completion
zstyle ':completion:*' insert-tab pending
# rehash if command not found (possibly recently installed)
zstyle ':completion:*' rehash true
# menu if nb items > 2
zstyle ':completion:*' menu select=2

# Rebuild the dump at most once a day; use the cached one otherwise. Runs after
# .zprofile has extended fpath so brew/distro completions are picked up.
ZSH_DISABLE_COMPFIX="true"
autoload -Uz compinit
# Note the array: [[ ]] performs no filename generation, so the qualifier has
# to be expanded somewhere that does. Plain (N.mh+24) rather than (#qN.mh+24)
# because the latter needs EXTENDED_GLOB, which isn't set here.
_zcompdump_stale=("$HOME"/.zcompdump(N.mh+24))
if [[ ! -f $HOME/.zcompdump ]] || (( $#_zcompdump_stale )); then
    compinit
    # compinit leaves an unchanged dump alone, so stamp it here or the 24h
    # clock never resets and every shell keeps taking the slow path.
    touch "$HOME/.zcompdump"
else
    compinit -C
fi
unset _zcompdump_stale
# }}}

# Key Bindings {{{
# ============
# Make sure that the terminal is in application mode when zle is active, since
# only then values from $terminfo are valid
if (( ${+terminfo[smkx]} )) && (( ${+terminfo[rmkx]} )); then
  function zle-line-init() {
    echoti smkx
  }
  function zle-line-finish() {
    echoti rmkx
  }
  zle -N zle-line-init
  zle -N zle-line-finish
fi

bindkey -e                                            # Use emacs key bindings

bindkey '\ew' kill-region                             # [Esc-w] - Kill from the cursor to the mark
bindkey -s '\el' 'ls\n'                               # [Esc-l] - run command: ls
bindkey '^r' history-incremental-search-backward      # [Ctrl-r] - Search backward incrementally for a specified string. The string may begin with ^ to anchor the search to the beginning of the line.
if [[ "${terminfo[kpp]}" != "" ]]; then
  bindkey "${terminfo[kpp]}" up-line-or-history       # [PageUp] - Up a line of history
fi
if [[ "${terminfo[knp]}" != "" ]]; then
  bindkey "${terminfo[knp]}" down-line-or-history     # [PageDown] - Down a line of history
fi

if [[ "${terminfo[khome]}" != "" ]]; then
  bindkey "${terminfo[khome]}" beginning-of-line      # [Home] - Go to beginning of line
fi
if [[ "${terminfo[kend]}" != "" ]]; then
  bindkey "${terminfo[kend]}"  end-of-line            # [End] - Go to end of line
fi

bindkey ' ' magic-space                               # [Space] - do history expansion

bindkey "\e\e[C" forward-word                         # [Alt-RightArrow] - move forward one word
bindkey "\e\e[D" backward-word                        # [Alt-LeftArrow] - move backward one word

bindkey '^?' backward-delete-char                     # [Backspace] - delete backward
if [[ "${terminfo[kdch1]}" != "" ]]; then
  bindkey "${terminfo[kdch1]}" delete-char            # [Delete] - delete forward
else
  bindkey "^[[3~" delete-char
  bindkey "^[3;5~" delete-char
  bindkey "\e[3~" delete-char
fi

# Start typing + [Up-Arrow] - fuzzy find history forward
if [[ -n "${terminfo[kcuu1]}" ]]; then
  autoload -U up-line-or-beginning-search
  zle -N up-line-or-beginning-search
  bindkey "${terminfo[kcuu1]}" up-line-or-beginning-search
fi
# Start typing + [Down-Arrow] - fuzzy find history backward
if [[ -n "${terminfo[kcud1]}" ]]; then
  autoload -U down-line-or-beginning-search
  zle -N down-line-or-beginning-search
  bindkey "${terminfo[kcud1]}" down-line-or-beginning-search
fi
# }}}

# Interactive fragments: aliases first, then plugins (which must bind keys
# after the bindings above are in place).
for _fragment in "$HOME"/.zshrc.d/*.zsh(N); do
    source "$_fragment"
done
unset _fragment
