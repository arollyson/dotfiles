###
autoload -Uz compinit
if [ $(date +'%j') != $(stat -f '%Sm' -t '%j' ~/.zcompdump) ]; then
  compinit
else
  compinit -C
fi

# Caching
export ZSH_CACHE_DIR=$HOME/.zsh/cache
export CLICOLOR=1

# Key Bindings {{{
# ======
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

bindkey '^[[1;5C' forward-word                        # [Ctrl-RightArrow] - move forward one word
bindkey '^[[1;5D' backward-word                       # [Ctrl-LeftArrow] - move backward one word

bindkey '^?' backward-delete-char                     # [Backspace] - delete backward
if [[ "${terminfo[kdch1]}" != "" ]]; then
  bindkey "${terminfo[kdch1]}" delete-char            # [Delete] - delete forward
else
  bindkey "^[[3~" delete-char
  bindkey "^[3;5~" delete-char
  bindkey "\e[3~" delete-char
fi
# }}}

# History {{{
# =======
# Keep 10000000 lines of history within the shell and save it to ~/.zsh_history:
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000000
SAVEHIST=10000000

setopt BANG_HIST                 # Treat the '!' character specially during expansion.
setopt EXTENDED_HISTORY          # Write the history file in the ":start:elapsed;command" format.
setopt INC_APPEND_HISTORY        # Write to the history file immediately, not when the shell exits.
setopt NO_SHARE_HISTORY          # Share history between all sessions.
setopt HIST_EXPIRE_DUPS_FIRST    # Expire duplicate entries first when trimming history.
setopt HIST_IGNORE_DUPS          # Don't record an entry that was just recorded again.
setopt HIST_IGNORE_ALL_DUPS      # Delete old recorded entry if new entry is a duplicate.
setopt HIST_FIND_NO_DUPS         # Do not display a line previously found.
setopt HIST_IGNORE_SPACE         # Don't record an entry starting with a space.
setopt HIST_SAVE_NO_DUPS         # Don't write duplicate entries in the history file.
setopt HIST_REDUCE_BLANKS        # Remove superfluous blanks before recording entry.
setopt HIST_VERIFY               # Don't execute immediately upon history expansion.
# }}}

# Completion stuff {{{
# ======
#completion listing extensions
zmodload -i zsh/complist
# Options
setopt COMPLETE_ALIASES   # Prevent aliases from being substituted before completion is attempted.
setopt COMPLETE_IN_WORD   # Attempt to start completion from both ends of a word.
setopt GLOB_COMPLETE      # Don't insert anything resulting from a glob pattern, show completion menu.
setopt NO_LIST_BEEP       # Don't beep on an ambiguous completion.
setopt LIST_PACKED        # Try to make the completion list smaller by drawing smaller columns.
setopt MENU_COMPLETE      # Instead of listing possibilities, select the first match immediately.
# forces zsh to realize new commands
zstyle ':completion:*' completer _oldlist _expand _complete _match _ignored _approximate
# Match dircolors with completion schema.
zstyle ':completion:*' list-colors ${(s#:#)LS_COLORS}
## case-insensitive (all),partial-word and then substring completion
if [ "x$CASE_SENSITIVE" = "xtrue" ]; then
    zstyle ':completion:*' matcher-list 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
    unset CASE_SENSITIVE
else
    zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
fi
# pasting with tabs doesn't perform completion
zstyle ':completion:*' insert-tab pending
# rehash if command not found (possibly recently installed)
zstyle ':completion:*' rehash true
# menu if nb items > 2
zstyle ':completion:*' menu select=2
# }}}

# Source antibody stuff
# Antibody {{{
# ======
# If plugins have not been downloaded, then download and static load in future.
if [[ ! -e "$HOME/.zsh_plugins.sh" ]]; then
    # Fetch plugins.
    antibody bundle < "$HOME/.zsh_plugins" > "$HOME/.zsh_plugins.sh"
fi

# Load plugins.
source "$HOME/.zsh_plugins.sh"
# }}}

# source zprofile
source ~/.zprofile
