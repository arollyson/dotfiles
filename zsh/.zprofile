# Detect our OS
case `uname` in
    Darwin)
        export DOTFILES_OS=osx
        export DOTFILES_BREW_PATH=/opt/homebrew/bin
    ;;
    Linux)
        export DOTFILES_OS=linux
        export DOTFILES_BREW_PATH=/home/linuxbrew/.linuxbrew/bin
  ;;
esac

if ! type brew &>/dev/null; then
    eval $($DOTFILES_BREW_PATH/brew shellenv)
fi

# Shell setup with brew
if type brew &>/dev/null; then
    _BREW_PREFIX=$(brew --prefix)

    FPATH=$_BREW_PREFIX/share/zsh/site-functions:$FPATH
    FPATH=$_BREW_PREFIX/share/zsh-completions:$FPATH
    source $_BREW_PREFIX/etc/profile.d/z.sh
    source $_BREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    source $_BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
    source $_BREW_PREFIX/share/zsh-history-substring-search/zsh-history-substring-search.zsh
    source $_BREW_PREFIX/opt/spaceship/spaceship.zsh
    autoload -Uz compinit
    compinit
fi

# Source OS specific profiles based on uname results
source $HOME/.zprofile.d/os.$DOTFILES_OS

# Source enironment specific profiles (work, server, personal, etc)
for file in ~/.zprofile.d/env.*; do
    source "$file"
done
