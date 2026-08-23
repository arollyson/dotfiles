#!/usr/bin/env zsh
# Interactive plugins, loaded from wherever the host actually installed them.
#
# Each plugin is looked up across brew, Debian/Ubuntu, Arch and manual install
# locations. A missing plugin degrades the prompt, it never breaks the shell —
# that is what keeps this config usable inside devcontainers.

_brew="${BREW_PREFIX:-/nonexistent}"

# --- nvm --------------------------------------------------------------------
dotfiles_source_first \
    "$_brew/opt/nvm/nvm.sh" \
    "$NVM_DIR/nvm.sh" \
    /usr/share/nvm/nvm.sh
dotfiles_source_first \
    "$_brew/opt/nvm/etc/bash_completion.d/nvm" \
    "$NVM_DIR/bash_completion"

# --- z ----------------------------------------------------------------------
dotfiles_source_first \
    "$_brew/etc/profile.d/z.sh" \
    /usr/share/z/z.sh \
    /etc/profile.d/z.sh

# --- fzf --------------------------------------------------------------------
if (( $+commands[fzf] )); then
    # fzf >= 0.48 ships its shell integration behind `--zsh`; older builds keep
    # it as files on disk.
    if fzf --zsh >/dev/null 2>&1; then
        eval "$(fzf --zsh)"
    else
        dotfiles_source_first \
            "$_brew/opt/fzf/shell/key-bindings.zsh" \
            /usr/share/doc/fzf/examples/key-bindings.zsh \
            /usr/share/fzf/key-bindings.zsh
        dotfiles_source_first \
            "$_brew/opt/fzf/shell/completion.zsh" \
            /usr/share/doc/fzf/examples/completion.zsh \
            /usr/share/fzf/completion.zsh
    fi

    if (( $+commands[rg] )); then
        export FZF_DEFAULT_COMMAND='rg --files --no-ignore --hidden --follow --glob "!.git"'
        export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    fi
    export FZF_DEFAULT_OPTS='--height 40% --reverse --border'
    if (( $+commands[bat] )); then
        export FZF_CTRL_T_OPTS="--preview 'bat --color=always --style=header,grid --line-range :500 {}'"
    fi
fi

# --- prompt -----------------------------------------------------------------
# Spaceship reads its own ~/.spaceshiprc.zsh for configuration.
dotfiles_source_first \
    "$_brew/opt/spaceship/spaceship.zsh" \
    "$HOME/.local/share/spaceship/spaceship.zsh" \
    /usr/share/zsh/site-functions/spaceship.zsh

# --- completion and line editing --------------------------------------------
dotfiles_source_first \
    "$_brew/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
    /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# Syntax highlighting wraps every widget defined so far, so it goes last of the
# widget-defining plugins.
dotfiles_source_first \
    "$_brew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
    /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
    /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# ...and history-substring-search must bind its keys after that wrapping.
if dotfiles_source_first \
    "$_brew/share/zsh-history-substring-search/zsh-history-substring-search.zsh" \
    /usr/share/zsh-history-substring-search/zsh-history-substring-search.zsh \
    /usr/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh
then
    bindkey "${terminfo[kcuu1]:-^[[A}" history-substring-search-up
    bindkey "${terminfo[kcud1]:-^[[B}" history-substring-search-down
fi

unset _brew
