# Set edit to vim
export EDITOR=vim

# Virtualenv
export WORKON_HOME=~/.virtualenvs
export PROJECT_HOME=~/dev

# Source OS specific profiles based on uname results
case `uname` in
  Darwin)
      source ~/.zprofile.os.osx
  ;;
  Linux)
      source ~/.zprofile.os.linux
  ;;
  FreeBSD)
      source ~/.zprofile.os.freebsd
  ;;
  CYGWIN)
      source ~/.zprofile.os.cygwin
  ;;
  MINGW)
      source ~/.zprofile.os.mingw
  ;;
esac

# Source enironment specific profiles (work, server, personal, etc)
for file in ~/.zprofile.env.*; do
    source "$file"
done
