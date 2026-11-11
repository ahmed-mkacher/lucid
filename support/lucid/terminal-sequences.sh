#!/usr/bin/env bash
# terminal-sequences.sh <colours.json>
#
# prints the OSC sequences that repaint a running terminal with a palette:
# foot (and xterm-likes) accept OSC 4 for the 16 ANSI colours, 10 fg, 11 bg,
# 12 cursor and 17 selection background. a shell cats the output it at a
# prompt, so a wallpaper change reaches terminals that are already open.
#
# the slots mirror support/matugen/templates/foot.ini, so the live repaint
# and a freshly opened terminal agree.

set -uo pipefail

P="${1:?usage: terminal-sequences.sh <colours.json>}"
[[ -f "$P" ]] || exit 0
command -v jq &>/dev/null || exit 0

c() { jq -r --arg k "$1" '.colors[$k].default.color // empty' "$P" 2>/dev/null; }

FG=$(c on_surface)
BG=$(c surface)
[[ -n "$FG" && -n "$BG" ]] || exit 0

printf '\033]10;%s\033\\' "$FG"
printf '\033]11;%s\033\\' "$BG"
printf '\033]12;%s\033\\' "$(c primary)"
printf '\033]17;%s\033\\' "$(c surface_variant)"

SLOTS=(
    "$(c surface)"          # 0
    "$(c error)"            # 1
    "$(c primary)"          # 2
    "$(c secondary)"        # 3
    "$(c primary)"          # 4
    "$(c inverse_primary)"  # 5
    "$(c primary_fixed)"    # 6
    "$(c on_surface)"       # 7
    "$(c surface_variant)"  # 8
    "$(c error)"            # 9
    "$(c primary)"          # 10
    "$(c secondary)"        # 11
    "$(c primary_fixed)"    # 12
    "$(c primary_fixed_dim)" # 13
    "$(c primary_fixed)"    # 14
    "$(c on_surface)"       # 15
)
i=0
for col in "${SLOTS[@]}"; do
    [[ -n "$col" ]] && printf '\033]4;%d;%s\033\\' "$i" "$col"
    i=$((i + 1))
done
printf '\n'
