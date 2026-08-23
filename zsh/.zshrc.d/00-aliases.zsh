#!/usr/bin/env zsh
# Aliases and small helper functions.

if (( $+commands[lsd] )); then
    alias ls='lsd'
    alias lt='ls --tree'
fi
alias ll='ls -l'
alias la='ls -a'
alias lla='ls -la'

if (( $+commands[rg] )); then
    alias rg="rg --hidden --glob '!\.git' --glob '!\.terraform'"
fi

alias gr='cd $(git rev-parse --show-toplevel)'

alias claude-yolo="claude --dangerously-skip-permissions"
alias claude-rc-yolo='claude remote-control --dangerously-skip-permissions'

# Render a JSON array of objects as an ASCII table, unioning keys across rows.
alias jqtable='jq -r '\''(reduce .[] as $item ({}; . * ($item | keys | map({(.): true}) | add))) as $allkeys | ($allkeys | keys) as $keys | (reduce .[] as $item ($keys | map({key: ., width: length}); . as $widths | [range(0; $keys|length)] as $indices | reduce $indices[] as $idx ($widths; .[$idx].width = ([.[$idx].width] + [($item[$keys[$idx]] // "-" | tostring | length)] | max)))) as $widths | "+" + ($widths | map("-" * (.width + 2)) | join("+")) + "+", "| " + ($widths | map(.key + (" " * ((.width - .key|length) + 1))) | join("| ")) + "|", "+" + ($widths | map("-" * (.width + 2)) | join("+")) + "+", (.[] | "| " + (. as $item | $widths | map((($item[.key] // "-") | tostring) + (" " * ((.width - (($item[.key] // "-") | tostring | length)) + 1))) | join("| ")) + "|"), "+" + ($widths | map("-" * (.width + 2)) | join("+")) + "+"'\'''

# Drop the cached stubs for the previous Yubikey so gpg re-reads the card.
switchyubi() {
    rm -rf -- "$HOME/.gnupg/private-keys-v1.d"
    gpgconf --kill gpg-agent
    gpg --card-status
}
