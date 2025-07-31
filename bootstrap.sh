#!/usr/bin/env bash

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

if ! command -v brew &> /dev/null
then
    echo "Installing brew"
    export NONINTERACTIVE=1
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/6895ebe7fd7e90478237d4219823f9c74e5e76fd/install.sh)"
    eval "$($DOTFILES_BREW_PATH/brew shellenv)"
fi

echo "Installing brew packages"
brew bundle install --file=Brewfile

echo "Installing dotfiles with stow"
stow git tmux vim zsh

echo "Setting shell to zsh"
chsh -s $(which zsh)

exec zsh
source ~/.zshrc
