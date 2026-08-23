#!/usr/bin/env zsh
# Login-shell environment: PATH and exported variables only.
#
# .zshrc sources this as a fallback for non-login interactive shells (some
# terminals and tmux configurations spawn those). The flag below makes that
# safe: whichever runs first wins, and the other skips.

_DOTFILES_ZPROFILE_LOADED=1

# --- Homebrew (optional) ----------------------------------------------------
# Brew is a convenience, not a dependency. Devcontainers and slim images will
# not have it, so nothing below may hard-depend on $BREW_PREFIX.
if (( ! $+commands[brew] )); then
    for _brew_candidate in \
        /opt/homebrew/bin/brew \
        /usr/local/bin/brew \
        /home/linuxbrew/.linuxbrew/bin/brew \
        "$HOME/.linuxbrew/bin/brew"
    do
        if [[ -x $_brew_candidate ]]; then
            eval "$("$_brew_candidate" shellenv)"
            break
        fi
    done
    unset _brew_candidate
fi

if (( $+commands[brew] )); then
    BREW_PREFIX="$(brew --prefix)"
    export BREW_PREFIX
    fpath=(
        "$BREW_PREFIX/share/zsh/site-functions"
        "$BREW_PREFIX/share/zsh-completions"
        $fpath
    )
fi

# --- Profile fragments ------------------------------------------------------
# OS-specific first, then environment-specific (work, personal, server). The
# (N) qualifier makes an empty match expand to nothing; without it zsh aborts
# the rest of this file.
[[ -r "$HOME/.zprofile.d/os.$DOTFILES_OS" ]] && source "$HOME/.zprofile.d/os.$DOTFILES_OS"

for _fragment in "$HOME"/.zprofile.d/env.*(N); do
    source "$_fragment"
done
unset _fragment
