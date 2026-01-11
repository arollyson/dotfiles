# Detect our OS
case `uname` in
    Darwin)
        export DOTFILES_OS=osx
        export DOTFILES_BREW_PATH=/opt/homebrew
    ;;
    Linux)
        export DOTFILES_OS=linux
        export DOTFILES_BREW_PATH=/home/linuxbrew/.linuxbrew
    ;;
esac

if ! type brew &>/dev/null; then
    eval $($DOTFILES_BREW_PATH/bin/brew shellenv)
fi

export BREW_PREFIX=$(brew --prefix)

# Shell setup with brew
if type brew &>/dev/null; then
    FPATH=$BREW_PREFIX/share/zsh/site-functions:$FPATH
    FPATH=$BREW_PREFIX/share/zsh-completions:$FPATH
    source $BREW_PREFIX/etc/profile.d/z.sh
    source $BREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    source $BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
    source $BREW_PREFIX/share/zsh-history-substring-search/zsh-history-substring-search.zsh
    source $BREW_PREFIX/opt/spaceship/spaceship.zsh
    autoload -Uz compinit
    compinit
fi

# Source OS specific profiles based on uname results
source $HOME/.zprofile.d/os.$DOTFILES_OS

# Source enironment specific profiles (work, server, personal, etc)
for file in ~/.zprofile.d/env.*; do
    source "$file"
done
