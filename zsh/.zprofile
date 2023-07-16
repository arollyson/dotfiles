# Set edit to vim
export EDITOR=vim

# Virtualenv
export WORKON_HOME=~/.virtualenvs
export PROJECT_HOME=~/dev

# Source OS specific profiles based on uname results
case `uname` in
  Darwin)
      source ~/.zprofile.d/os.osx
  ;;
  Linux)
      source ~/.zprofile.d/os.linux
  ;;
  FreeBSD)
      source ~/.zprofile.d/os.freebsd
  ;;
  CYGWIN)
      source ~/.zprofile.d/os.cygwin
  ;;
  MINGW)
      source ~/.zprofile.d/os.mingw
  ;;
esac

# Source enironment specific profiles (work, server, personal, etc)
for file in ~/.zprofile.d/env.*; do
    source "$file"
done
