#!/usr/bin/env zsh
# Sourced by every zsh: login, interactive, and scripts alike.
# Keep this cheap and free of side effects.

# Ubuntu's /etc/zsh/zshrc runs a bare `compinit` before ~/.zshrc gets a say,
# and a bare compinit stops to ask about insecure directories, then aborts.
# This is the opt-out it documents; our own compinit -i runs later in .zshrc.
skip_global_compinit=1

# Tie `path`/`fpath` arrays to their scalar counterparts and drop duplicates
# automatically. This is what makes repeated sourcing of profile fragments
# harmless instead of accumulating entries.
typeset -U path fpath

# Platform label consumed by .zprofile and .zprofile.d/os.*
case "$(uname -s)" in
    Darwin) DOTFILES_OS=osx ;;
    Linux)  DOTFILES_OS=linux ;;
    *)      DOTFILES_OS=unknown ;;
esac
export DOTFILES_OS

# Source the first readable file from the candidates given, and report whether
# anything matched. Used throughout to keep Homebrew optional: a devcontainer
# with distro packages must work as well as a Mac with brew.
dotfiles_source_first() {
    local candidate
    for candidate in "$@"; do
        if [[ -r $candidate ]]; then
            source "$candidate"
            return 0
        fi
    done
    return 1
}
