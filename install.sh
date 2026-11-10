#!/usr/bin/env bash
# Lucid installer — Arch Linux + Hyprland
#
# installs dependencies, places the shell at ~/.config/quickshell, and sets up
# the full bundle: the Hyprland config (binds, window rules, blur, autostart),
# the theming layer, the Lucid look, and what the dock pins.
# safe to re-run: existing config and personal state are backed up, never
# overwritten in place.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# the VERSION file ships inside the shell tree, so the installed copy can tell
# the update check which version it is. bump it to cut a release
VERSION="unknown"
if [[ -f "$SRC/VERSION" ]]; then
    VERSION="$(tr -d '[:space:]' < "$SRC/VERSION")"
fi
SHELL_DIR="$HOME/.config/quickshell"
LUCID_DIR="$HOME/.config/lucid"
MATUGEN_DIR="$HOME/.config/matugen"
WALL_SCRIPT_DIR="$HOME/.config/hypr/scripts/wallpaper"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP=""

WITH_THEMING=1
WITH_LOOK=1
WITH_HYPR=1
WITH_APPS=1
WITH_WALLPAPERS=1
HYPR_FORCE=0
HYPR_LUA_INSTALLED=0
ASSUME_YES=0
SKIP_DEPS=0
# app picker choices. PICK_DEFAULT is keyed by binding id (browser, terminal,
# files, editor) and holds the app picked as that section's default
PICK_SELECTED=()
declare -A PICK_DEFAULT=()
# the look checklist's ticks, keyed by item (fastfetch, foot, kitty)
declare -A LOOK_SELECTED=()

b=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; grn=$'\e[32m'; ylw=$'\e[33m'; r=$'\e[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s\n' "$grn" "$r" "$b" "$*$r"; }
warn() { printf '%s warning:%s %s\n' "$ylw" "$r" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$red" "$r" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
${b}Lucid $VERSION installer${r}

  ./install.sh [options]

  --no-theming   skip the palette layer; leave ~/.config/lucid
                 and ~/.config/matugen untouched
  --no-look      don't touch fastfetch, foot or kitty configs
  --no-hypr      keep your Hyprland config; Lucid's binds, window
                 rules and blur are not installed
  --no-apps      skip the app picker: no apps are installed and
                 the dock is left unpinned
  --no-wallpapers
                 don't copy the bundled wallpapers to
                 ~/Pictures/wallpapers
  --with-hypr    reinstall Lucid's Hyprland config even when one
                 is already in place
  --skip-deps    don't install packages, only check for them
  -y, --yes      don't prompt, accept every default (the app
                 picker is skipped, so no apps are installed)
  -h, --help     this message

  ${b}Apps${r}
  during the dependencies step a picker lists an optional browser,
  terminal, file manager, editor, office suite and notes apps. Up/Down
  or k/j move, space toggles, d sets that section's default, enter
  finishes. Apps are optional: tick nothing and none are installed.
  Only browser, terminal, files and editor have a bind, so d does
  nothing on the others. The file manager default is what SUPER + E
  opens.

  ${b}Look${r}
  a second picker offers fastfetch, the foot palette include and the
  kitty config. Tick only what you want; nothing is applied
  otherwise. --no-look skips it whole.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-theming) WITH_THEMING=0 ;;
        --no-look)    WITH_LOOK=0 ;;
        --no-hypr)    WITH_HYPR=0 ;;
        --no-apps)    WITH_APPS=0 ;;
        --no-wallpapers) WITH_WALLPAPERS=0 ;;
        --with-hypr)  WITH_HYPR=1; HYPR_FORCE=1 ;;
        --skip-deps)  SKIP_DEPS=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        -h|--help)    usage ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

ask() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -rp "$1 [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- preflight

step "Checking the system"

[[ -f /etc/arch-release ]] || die "this installer is Arch-only. see the README for a manual install."
command -v pacman &>/dev/null || die "pacman not found"
[[ $EUID -ne 0 ]] || die "don't run this as root — it installs into your home directory"
[[ -f "$SRC/shell.qml" ]] || die "run this from inside the Lucid repo (no shell.qml next to install.sh)"

command -v Hyprland &>/dev/null || command -v hyprctl &>/dev/null \
    || warn "Hyprland not found. Lucid uses Hyprland-specific APIs and will not work under another compositor."

AUR=""
for helper in paru yay; do
    command -v "$helper" &>/dev/null && { AUR="$helper"; break; }
done

say "  arch linux      ${grn}ok${r}"
say "  aur helper      ${AUR:-${ylw}none${r}}"
say "  install target  $SHELL_DIR"
say "  theming layer   $([[ $WITH_THEMING -eq 1 ]] && echo yes || echo 'no (--no-theming)')"
say "  hyprland config $([[ $WITH_HYPR   -eq 1 ]] && echo yes || echo 'no (--no-hypr)')"
say "  dock pins       $([[ $WITH_APPS   -eq 1 ]] && echo yes || echo 'no (--no-apps)')"
say "  wallpapers      $([[ $WITH_WALLPAPERS -eq 1 ]] && echo yes || echo 'no (--no-wallpapers)')"

# ------------------------------------------------------------- dependencies

# required — the shell will not start or will visibly break without these
PKG_REQUIRED=(quickshell qt6-5compat qt6-declarative qt6-multimedia)
# each of these backs one feature; missing ones degrade that feature only
PKG_FEATURES=(
    matugen jq imagemagick
    networkmanager qrencode bluez bluez-utils bluez-obex
    libpulse wireplumber brightnessctl upower hypridle hyprsunset
    grim wf-recorder ffmpeg wl-clipboard wtype cliphist
    tesseract tesseract-data-eng hyprpicker
    python-pillow python-numpy python-fonttools
    cava songrec curl libnotify awww
    noto-fonts-emoji
    # the shell is the session's own polkit agent; polkitd and its setuid
    # helper are the backend it drives
    xdg-utils swappy polkit
    # the accounts page reads and writes users through this, and asks the
    # shell's polkit dialog whenever a change needs an administrator
    accountsservice
    # the environment page writes the desktop's appearance through these, and
    # the file chooser apps pick files with comes from the gtk portal.
    # librsvg renders a cursor theme again when its shadow is turned off
    gsettings-desktop-schemas xdg-desktop-portal-gtk librsvg
    # the launcher's $ mode runs a command in the user's terminal through this
    xdg-terminal-exec
    # the camera on/off toast hears /dev/video* opened and closed through this
    inotify-tools
    # the Storage page: a drive's health, and mounting or ejecting one
    smartmontools udisks2
)
# invoked by the shipped Hyprland binds and the Lucid look. without these the
# config installs fine but its keys do nothing and the look renders as boxes
PKG_HYPR=(
    playerctl starship fish ttf-jetbrains-mono-nerd
)
# a package already covered by an equivalent one the user chose themselves.
# without this a re-run keeps trying to install Lucid's pick over theirs
declare -A PKG_ALTS=(
    [ttf-jetbrains-mono-nerd]="nerd-fonts ttf-jetbrains-mono"
    [xdg-desktop-portal-gtk]="xdg-desktop-portal-gnome xdg-desktop-portal-kde"
)

# true when the package, or anything standing in for it, is installed
have_pkg() {
    pacman -Qq "$1" &>/dev/null && return 0
    local alt
    for alt in ${PKG_ALTS[$1]:-}; do
        pacman -Qq "$alt" &>/dev/null && return 0
    done
    return 1
}

# inline checkbox picker for the optional apps. installed apps start ticked; a
# section whose only ticked app is installed starts with it as that section's
# default. choices land in PICK_SELECTED (packages) and PICK_DEFAULT (binding
# id -> exec) when the picker exits. drawn in place rather than full-screen:
# the list is printed once and rewritten with cursor-up, so the scrollback
# keeps it after the picker is gone.
pick_apps() {
    local -a rows=(
        "Browser|browser|Zen|zen-browser-bin|zen-browser"
        "Browser|browser|Helium|helium-browser-bin|helium"
        "Browser|browser|Firefox|firefox|firefox"
        "Browser|browser|LibreWolf|librewolf|librewolf"
        "Browser|browser|Chromium|chromium|chromium"
        "Terminal|terminal|foot|foot|foot"
        "Terminal|terminal|kitty|kitty|kitty"
        "Terminal|terminal|Alacritty|alacritty|alacritty"
        "Terminal|terminal|WezTerm|wezterm|wezterm"
        "Terminal|terminal|Ghostty|ghostty|ghostty"
        "File manager|files|Thunar|thunar|thunar"
        "File manager|files|Nautilus|nautilus|nautilus"
        "File manager|files|Nemo|nemo|nemo"
        "File manager|files|Dolphin|dolphin|dolphin"
        "File manager|files|PCManFM|pcmanfm|pcmanfm"
        "Editor|editor|Zed|zed|zeditor"
        "Editor|editor|VSCodium|vscodium-bin|codium"
        "Editor|editor|VS Code|code|code"
        "Office|office|LibreOffice|libreoffice-fresh|libreoffice"
        "Office|office|ONLYOFFICE|onlyoffice-bin|onlyoffice-desktopeditors"
        "Notes|notes|Obsidian|obsidian-bin|obsidian"
        "Notes|notes|Notion|notion-app-electron|notion-app-electron"
        "Notes|notes|Logseq|logseq-desktop-bin|logseq"
        "Notes|notes|Joplin|joplin-desktop|joplin-desktop"
    )
    # each section's header says where that category lands, where it does
    local -A sec_note=(
        [browser]="opens in the scratchpad (SUPER + S) · SUPER + W opens the default"
        [terminal]="SUPER + Return opens the default"
        [files]="SUPER + E opens the default"
        [editor]="SUPER + C opens the default"
        [notes]="opens in the To-do workspace (SUPER + R)"
    )
    local -a sec=() sid=() label=() pkg=() exe=()
    local -A on=() have=() def=()
    local rec s i l p e cur=0 cnt only key k2 k3 mark note lines picked defs d skip="" quit="" row changed=0

    for rec in "${rows[@]}"; do
        IFS='|' read -r s i l p e <<< "$rec"
        sec+=("$s"); sid+=("$i"); label+=("$l"); pkg+=("$p"); exe+=("$e")
    done

    for i in "${!pkg[@]}"; do
        if have_pkg "${pkg[i]}"; then
            on[$i]=1
            have[$i]=1
        fi
    done

    # a section with exactly one installed app gets it as the default
    for s in browser terminal files editor; do
        cnt=0; only=-1
        for i in "${!pkg[@]}"; do
            [[ ${sid[i]} == "$s" ]] || continue
            [[ -n ${have[$i]:-} ]] || continue
            cnt=$((cnt + 1))
            only=$i
        done
        if [[ $cnt -eq 1 ]]; then def[$s]=$only; fi
    done

    # Ctrl-C must not leave the terminal with a hidden cursor, reverse video or
    # a muted tty
    trap 'stty echo 2>/dev/null || true; printf "\e[0m\e[?25h"; exit 130' INT TERM
    printf '\e[?25l'
    # echo stays off for the whole picker: between reads the tty would print
    # keys pressed while the redraw runs all over the list
    stty -echo 2>/dev/null || true

    lines=0
    # one printf per row and every row is cut to the terminal width, so a row
    # is always exactly one visual row and counting back cannot drift.
    line() {
        local st="$1" row="$2"
        row=${row:0:cols-1}
        printf '%s%s\e[0m\e[K\n' "$st" "$row"
        lines=$((lines + 1))
    }
    draw() {
        cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
        if (( lines > 0 )); then printf '\e[%dA' "$lines"; fi
        lines=0
        line "$b" "Apps to install"
        line "$dim" "optional - Lucid runs without any of these"
        s=""
        for i in "${!pkg[@]}"; do
            if [[ ${sec[i]} != "$s" ]]; then
                s=${sec[i]}
                note=${sec_note[${sid[i]}]:-}
                line "" ""
                line "$b" " $s${note:+ $note}"
            fi
            mark="[ ]"
            if [[ -n ${on[$i]:-} ]]; then mark="[x]"; fi
            note=""
            if [[ -n ${have[$i]:-} ]]; then note="(installed)"; fi
            if [[ ${def[${sid[i]}]:-} == "$i" ]]; then
                note="${note:+$note }(default)"
            fi
            printf -v row ' %s %-18s%s' "$mark" "${label[i]}" "${note:+ $note}"
            if [[ $i -eq $cur ]]; then
                line $'\e[7m' "$row"
            elif [[ -n ${have[$i]:-} ]]; then
                # installed rows are locked on, so they read as done, not open
                line "$dim" "$row"
            else
                line "" "$row"
            fi
        done
        line "" ""
        line "$dim" "  up/down or j/k move   space toggle   d default   enter install   s skip   q quit"
    }

    draw
    while :; do
        changed=0
        IFS= read -rsn1 key || key=""
        if [[ -z $key || $key == $'\n' ]]; then break; fi
        if [[ $key == $'\e' ]]; then
            # arrows arrive as ESC [ A/B
            IFS= read -rsn1 -t 0.02 k2 || k2=""
            if [[ $k2 == '[' ]]; then
                IFS= read -rsn1 -t 0.02 k3 || k3=""
                case "$k3" in
                    A) if (( cur > 0 )); then cur=$((cur - 1)); changed=1; fi ;;
                    B) if (( cur < ${#pkg[@]} - 1 )); then cur=$((cur + 1)); changed=1; fi ;;
                esac
            fi
        else
            case "$key" in
                s) skip=1; break ;;
                q) quit=1; break ;;
                k) if (( cur > 0 )); then cur=$((cur - 1)); changed=1; fi ;;
                j) if (( cur < ${#pkg[@]} - 1 )); then cur=$((cur + 1)); changed=1; fi ;;
                ' ')
                    # an installed app stays selected: space leaves it alone
                    if [[ -z ${have[$cur]:-} ]]; then
                        if [[ -n ${on[$cur]:-} ]]; then
                            unset "on[$cur]"
                            # a default that is no longer selected is no default
                            if [[ ${def[${sid[cur]}]:-} == "$cur" ]]; then
                                unset "def[${sid[cur]}]"
                            fi
                        else
                            on[$cur]=1
                        fi
                        changed=1
                    fi
                    ;;
                d)
                    # only the four sections with a bind can hold a default
                    case "${sid[cur]}" in
                        browser|terminal|files|editor)
                            if [[ -n ${on[$cur]:-} ]]; then
                                if [[ ${def[${sid[cur]}]:-} == "$cur" ]]; then
                                    unset "def[${sid[cur]}]"
                                else
                                    def[${sid[cur]}]=$cur
                                fi
                                changed=1
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi
        if (( changed )); then draw; fi
    done

    # one short drain of keys still queued, so a held key cannot spill onto the
    # next prompt
    while IFS= read -rsn1 -t 0.01 _; do :; done
    trap - INT TERM
    stty echo 2>/dev/null || true
    printf '\e[0m\e[?25h\n'

    if [[ -n $quit ]]; then printf 'stopped.\n'; exit 1; fi

    if [[ -n $skip ]]; then
        PICK_SELECTED=()
        PICK_DEFAULT=()
        printf '  apps skipped\n'
        return 0
    fi

    PICK_SELECTED=()
    for i in "${!pkg[@]}"; do
        if [[ -n ${on[$i]:-} ]]; then PICK_SELECTED+=("${pkg[i]}"); fi
    done
    PICK_DEFAULT=()
    for i in "${!pkg[@]}"; do
        if [[ ${def[${sid[i]}]:-} == "$i" ]]; then PICK_DEFAULT[${sid[i]}]=${exe[i]}; fi
    done

    picked="none"
    (( ${#PICK_SELECTED[@]} )) && picked="${PICK_SELECTED[*]}"
    defs="none"
    d=""
    for key in browser terminal files editor; do
        if [[ -n ${PICK_DEFAULT[$key]:-} ]]; then d+="${d:+, }$key=${PICK_DEFAULT[$key]}"; fi
    done
    [[ -n "$d" ]] && defs="$d"
    printf '  selected: %s   default: %s\n' "$picked" "$defs"
}

# rewrite the four shipped app binds to the picker's defaults. only the line
# carrying the binding's unique id is edited; nothing else is reformatted.
apply_app_binds() {
    local f="$LUCID_DIR/keybinds.json" exec id
    [[ -f "$f" ]] || return 0

    exec=${PICK_DEFAULT[browser]:-}
    if [[ -n "$exec" ]]; then
        sed -i "/\"id\": \"browser\"/ s|\"lua\": \".*\"|\"lua\": \"specials.launch(\\\\\"special\\\\\", \\\\\"$exec\\\\\")\"|" "$f"
    fi

    for id in terminal files editor; do
        exec=${PICK_DEFAULT[$id]:-}
        if [[ -n "$exec" ]]; then
            sed -i "/\"id\": \"$id\"/ s|\"cmd\": \"[^\"]*\"|\"cmd\": \"$exec\"|" "$f"
        fi
    done
}

missing=()
DEPS_OK=1

step "Resolving dependencies"

# a never-synced pacman database makes every -Si lookup fail, so real repo
# packages get misread as AUR and nothing installs. check against a package
# that is guaranteed present rather than trusting the db exists.
if ! pacman -Si bash &>/dev/null; then
    warn "your pacman database is empty or stale — package lookups will fail."
    warn "run this first, then re-run the installer:"
    warn "    sudo pacman -Syu"
    if ! ask "  Continue anyway (dependencies will likely be skipped)?"; then
        die "stopped. run 'sudo pacman -Syu' and try again."
    fi
fi

WANTED=("${PKG_REQUIRED[@]}" "${PKG_FEATURES[@]}")
[[ $WITH_HYPR -eq 1 || $WITH_LOOK -eq 1 ]] && WANTED+=("${PKG_HYPR[@]}")

# optional apps are chosen here and then join the same repo/AUR flow below.
# skipped entirely with --no-apps, -y, or when there is no terminal to draw in
if [[ $WITH_APPS -eq 1 && $ASSUME_YES -eq 0 && -t 0 ]]; then
    pick_apps
    if (( ${#PICK_SELECTED[@]} )); then
        WANTED+=("${PICK_SELECTED[@]}")
    fi
fi

for p in "${WANTED[@]}"; do
    have_pkg "$p" || missing+=("$p")
done

if [[ ${#missing[@]} -eq 0 ]]; then
    say "  everything is already installed"
elif [[ $SKIP_DEPS -eq 1 ]]; then
    DEPS_OK=0
    say "  ${ylw}missing (--skip-deps, not installing):${r}"
    printf '    %s\n' "${missing[@]}"
else
    # split by what the configured repos actually carry, so one unresolvable
    # name can never take the whole batch down with it
    from_repo=(); from_aur=()
    for p in "${missing[@]}"; do
        if pacman -Si "$p" &>/dev/null; then from_repo+=("$p"); else from_aur+=("$p"); fi
    done

    [[ ${#from_repo[@]} -gt 0 ]] && say "  from the repos: ${from_repo[*]}"
    [[ ${#from_aur[@]}  -gt 0 ]] && say "  not in your repos, will try the aur: ${from_aur[*]}"

    if ask "  install these now?"; then
        if [[ ${#from_repo[@]} -gt 0 ]]; then
            if sudo pacman -S --needed --noconfirm "${from_repo[@]}"; then
                say "  repo packages installed"
            else
                DEPS_OK=0
                warn "some repo packages failed to install — continuing anyway"
            fi
        fi
        if [[ ${#from_aur[@]} -gt 0 ]]; then
            if [[ -n "$AUR" ]]; then
                # one at a time: a single bad name shouldn't block the rest
                for p in "${from_aur[@]}"; do
                    "$AUR" -S --needed --noconfirm "$p" || {
                        DEPS_OK=0; warn "could not install $p"
                    }
                done
            else
                DEPS_OK=0
                warn "no AUR helper (paru/yay) — install manually: ${from_aur[*]}"
            fi
        fi
    else
        DEPS_OK=0
        warn "skipping. features backed by the missing packages will not work."
    fi
fi

# --------------------------------------------------------------- the shell

step "Installing the shell"

if [[ "$SRC" == "$SHELL_DIR" ]]; then
    say "  already at $SHELL_DIR, installing in place"
else
    if [[ -e "$SHELL_DIR" ]]; then
        BACKUP="$SHELL_DIR.backup-$STAMP"
        say "  existing config found, moving it to ${dim}$BACKUP${r}"
        mv "$SHELL_DIR" "$BACKUP"
    fi
    mkdir -p "$SHELL_DIR"
    # everything but the repo's own scaffolding. runtime state is excluded
    # too, so the copy can never carry another machine's settings, pins or
    # api keys — those come from defaults/ in the seed step below
    tar -C "$SRC" -cf - \
        --exclude='.git' --exclude='.github' --exclude='.claude' \
        --exclude='support' --exclude='defaults' --exclude='__pycache__' \
        --exclude='wallpapers' \
        --exclude='install.sh' --exclude='uninstall.sh' \
        --exclude='README.md' --exclude='LICENSE' --exclude='.gitignore' \
        --exclude='./lucidprefs/prefs.json' \
        --exclude='./lucidbar/blur.json' \
        --exclude='./lucidbar/clock_reminders.json' \
        --exclude='./lucidbar/mpris_shazam.json' \
        --exclude='./luciddocks/pinned.json' \
        --exclude='./luciddocks/usage.json' \
        --exclude='./luciddocks/wallpaper.json' \
        --exclude='./lucidmoji/config.json' \
        --exclude='./lucidmoji/state.json' \
        --exclude='./lucidkeys/state.json' \
        --exclude='./lucidwidgets/widgets.json' \
        --exclude='./luciddesktop/icons.json' \
        . | tar -C "$SHELL_DIR" -xf -
    say "  shell files -> $SHELL_DIR"
fi

# the shell loads its bundled font itself, but the apps the environment page
# dresses (and its font picker) only see what fontconfig knows. google sans
# flex is the OFL release, so it may ship; the proprietary google sans may not
if [[ -f "$SRC/assets/fonts/GoogleSansFlex.ttf" ]]; then
    FONT_DIR="$HOME/.local/share/fonts/lucid"
    mkdir -p "$FONT_DIR"
    install -m644 "$SRC/assets/fonts/GoogleSansFlex.ttf" "$FONT_DIR/GoogleSansFlex.ttf"
    install -m644 "$SRC/assets/fonts/OFL-GoogleSansFlex.txt" "$FONT_DIR/OFL-GoogleSansFlex.txt"
    fc-cache -f "$FONT_DIR" &>/dev/null || true
    say "  google sans flex -> $FONT_DIR"
fi

# the launcher sits outside the shell tree so autostart can reach it whether or
# not the Hyprland config was installed. it picks the Qt scene graph backend
# before exec'ing quickshell — see support/lucid/launch-shell.sh
if [[ -f "$SRC/support/lucid/launch-shell.sh" ]]; then
    mkdir -p "$LUCID_DIR"
    install -m755 "$SRC/support/lucid/launch-shell.sh" "$LUCID_DIR/launch-shell.sh"
    say "  shell launcher -> $LUCID_DIR/launch-shell.sh"
else
    warn "support/lucid/launch-shell.sh missing, autostart will run quickshell directly"
fi

# state files. a re-run keeps your settings: anything already in place wins,
# then whatever the previous install left in the backup, and only failing both
# does the shipped default get written
seed() {
    local src="$SRC/defaults/$1" dest="$SHELL_DIR/$2"
    mkdir -p "$(dirname "$dest")"
    if [[ -s "$dest" ]]; then
        say "  ${dim}keeping existing $2${r}"
    elif [[ -n "$BACKUP" && -s "$BACKUP/$2" ]]; then
        cp "$BACKUP/$2" "$dest"
        say "  carried over $2"
    else
        cp "$src" "$dest"
        say "  seeded $2"
    fi
}

# pinned dock apps are detected rather than shipped: a fixed list pins apps the
# machine does not have, and the dock can only draw a letter tile for those
detect_pinned() {
    local dirs=(
        /usr/share/applications
        "$HOME/.local/share/applications"
        /var/lib/flatpak/exports/share/applications
        "$HOME/.local/share/flatpak/exports/share/applications"
    )
    # the shipped dock lineup, in dock order. one entry per slot and first
    # match wins, so a machine without Lucid's default app still gets that
    # slot filled by whatever equivalent it does have
    local slots=(
        "zen zen-browser app.zen_browser.zen firefox librewolf chromium brave-browser google-chrome-stable"
        "vscodium codium code code-oss com.visualstudio.code zed dev.zed.Zed"
        "spotify com.spotify.Client spotify-launcher"
        "vesktop dev.vencord.Vesktop discord com.discordapp.Discord webcord"
        "org.gnome.Nautilus nautilus org.kde.dolphin dolphin thunar nemo pcmanfm-qt pcmanfm"
        "steam com.valvesoftware.Steam"
        "proton.vpn.app.gtk protonvpn-app"
        "kitty alacritty foot org.wezfurlong.wezterm Alacritty com.mitchellh.ghostty"
    )
    local out="" found=0
    for slot in "${slots[@]}"; do
        for cand in $slot; do
            local f=""
            for d in "${dirs[@]}"; do
                [[ -f "$d/$cand.desktop" ]] && { f="$d/$cand.desktop"; break; }
            done
            [[ -n "$f" ]] || continue

            local name icon exec wm
            name=$(sed -n 's/^Name=//p'           "$f" | head -n1)
            icon=$(sed -n 's/^Icon=//p'           "$f" | head -n1)
            # strip desktop field codes, then drop any option left holding
            # nothing (Exec=spotify --uri=%u would otherwise pin "--uri=")
            exec=$(sed -n 's/^Exec=//p' "$f" | head -n1 \
                | sed -E 's/%[fFuUdDnNickvm]//g; s/ +-[^ ]*=( |$)/\1/g; s/  +/ /g; s/ +$//')
            wm=$(  sed -n 's/^StartupWMClass=//p' "$f" | head -n1)
            [[ -n "$name" && -n "$exec" ]] || continue
            # StartupWMClass is an X11 hint. a wayland-native app reports its
            # application-id instead, which is the reverse-dns desktop name -
            # trusting the hint there pins an id no window ever matches
            if [[ "$cand" == *.*.* ]]; then
                wm="$cand"
            else
                [[ -n "$wm" ]] || wm="$cand"
            fi
            [[ -n "$icon" ]] || icon="$cand"
            # escape for json
            esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
            [[ $found -eq 1 ]] && out+=","
            out+=$(printf '\n        {\n            "appId": "%s",\n            "appKey": "%s",\n            "command": "%s",\n            "iconName": "%s",\n            "name": "%s"\n        }' \
                "$(esc "$wm")" "$(esc "$cand")" "$(esc "$exec")" "$(esc "$icon")" "$(esc "$name")")
            found=1
            break
        done
    done
    [[ $found -eq 1 ]] || return 1
    printf '{\n    "pinnedApps": [%s\n    ]\n}\n' "$out"
}

seed_pinned() {
    local dest="$SHELL_DIR/luciddocks/pinned.json"
    mkdir -p "$(dirname "$dest")"
    if [[ -s "$dest" ]]; then
        say "  ${dim}keeping existing luciddocks/pinned.json${r}"
    elif [[ -n "$BACKUP" && -s "$BACKUP/luciddocks/pinned.json" ]]; then
        cp "$BACKUP/luciddocks/pinned.json" "$dest"
        say "  carried over luciddocks/pinned.json"
    elif [[ $WITH_APPS -eq 0 ]]; then
        rm -f "$dest.tmp"
        printf '{\n    "pinnedApps": []\n}\n' > "$dest"
        say "  dock left unpinned (--no-apps)"
    elif detect_pinned > "$dest.tmp" 2>/dev/null && [[ -s "$dest.tmp" ]]; then
        mv "$dest.tmp" "$dest"
        say "  pinned $(grep -c '"appId"' "$dest") installed apps to the dock"
    else
        rm -f "$dest.tmp"
        cp "$SRC/defaults/pinned.json" "$dest"
        say "  seeded luciddocks/pinned.json (defaults)"
    fi
}

seed prefs.json            lucidprefs/prefs.json
seed blur.json             lucidbar/blur.json
seed clock_reminders.json  lucidbar/clock_reminders.json
seed mpris_shazam.json     lucidbar/mpris_shazam.json
seed_pinned
seed usage.json            luciddocks/usage.json
seed wallpaper.json        luciddocks/wallpaper.json
seed moji-config.json      lucidmoji/config.json
seed moji-state.json       lucidmoji/state.json
seed keys-state.json       lucidkeys/state.json
seed widgets.json          lucidwidgets/widgets.json
# where the desktop icons sit has no shipped default: only carried over
if [[ ! -s "$SHELL_DIR/luciddesktop/icons.json" && -n "$BACKUP" && -s "$BACKUP/luciddesktop/icons.json" ]]; then
    mkdir -p "$SHELL_DIR/luciddesktop"
    cp "$BACKUP/luciddesktop/icons.json" "$SHELL_DIR/luciddesktop/icons.json"
    say "  carried over luciddesktop/icons.json"
fi

# the media visualiser runs `cava -p ~/.config/cava/quickshell.conf`. without
# that file cava falls back to its own defaults, which emit ncurses output
# instead of the raw ascii frames the bar strip parses - the strip then reads
# one enormous bar and draws it as a circle across the whole popup. not part of
# --no-look: this backs a shell feature, it is not a taste preference.
CAVA_CFG="$HOME/.config/cava/quickshell.conf"
mkdir -p "$(dirname "$CAVA_CFG")"
if [[ ! -f "$CAVA_CFG" ]]; then
    cp "$SRC/support/cava/quickshell.conf" "$CAVA_CFG"
    say "  cava visualiser config -> ~/.config/cava/quickshell.conf"
elif cmp -s "$SRC/support/cava/quickshell.conf" "$CAVA_CFG"; then
    say "  ${dim}keeping cava/quickshell.conf${r}"
else
    cp "$CAVA_CFG" "$CAVA_CFG.backup-$STAMP"
    cp "$SRC/support/cava/quickshell.conf" "$CAVA_CFG"
    say "  cava/quickshell.conf refreshed (yours -> quickshell.conf.backup-$STAMP)"
fi

# the Environment page writes the Qt half of the appearance - style, icon theme
# and fonts - into qt6ct.conf, and the shipped modules/env.lua exports
# QT_QPA_PLATFORMTHEME=qt6ct so Qt apps read it. envtool.py deliberately never
# creates that file: it refuses to conjure a config for a toolkit the machine
# does not use. so on a fresh machine the page's Qt switch is a silent no-op
# until something writes one. minimal on purpose - the page fills in the style,
# icons and fonts itself on the first apply.
QT6CT_CFG="$HOME/.config/qt6ct/qt6ct.conf"
if ! command -v qt6ct &>/dev/null; then
    say "  ${dim}qt6ct is not installed - the Environment page will skip Qt${r}"
elif [[ -f "$QT6CT_CFG" ]]; then
    say "  ${dim}keeping qt6ct/qt6ct.conf${r}"
else
    mkdir -p "$(dirname "$QT6CT_CFG")"
    printf '[Appearance]\nstyle=Fusion\n' > "$QT6CT_CFG"
    say "  qt6ct.conf -> ~/.config/qt6ct/qt6ct.conf"
fi

# --------------------------------------------------- notification ownership

# org.freedesktop.Notifications is a single-owner D-Bus name and Lucid's bar
# serves it. Any other notification daemon that is merely *installed* can be
# D-Bus-activated the moment something posts a notification - it does not have
# to be autostarted - and whoever claims the name first keeps it for the whole
# session. Lose that race and Lucid's toasts silently never appear: you get the
# other daemon's notification instead, while the bar looks perfectly fine.

step "Checking who serves notifications"

NOTIFY_RIVALS=()
for f in /usr/share/dbus-1/services/*.service "$HOME/.local/share/dbus-1/services/"*.service; do
    [[ -f "$f" ]] || continue
    grep -q '^Name=org.freedesktop.Notifications' "$f" || continue
    grep -qi 'quickshell' "$f" && continue
    NOTIFY_RIVALS+=("$f")
done

if [[ ${#NOTIFY_RIVALS[@]} -eq 0 ]]; then
    say "  ${dim}nothing else claims the name — Lucid's notifications win${r}"
else
    for f in "${NOTIFY_RIVALS[@]}"; do
        unit=$(sed -n 's/^SystemdService=//p' "$f" | head -n1)
        exe=$(sed -n 's/^Exec=//p' "$f" | head -n1 | awk '{print $1}')
        say "  ${ylw}$(basename "$exe")${r} also claims org.freedesktop.Notifications"
        say "  ${dim}($f)${r}"
    done
    say "  D-Bus starts it on the first notification, and it then keeps the"
    say "  name for the session — Lucid's own notifications never show."

    if ask "  Stop it taking over?"; then
        for f in "${NOTIFY_RIVALS[@]}"; do
            unit=$(sed -n 's/^SystemdService=//p' "$f" | head -n1)
            exe=$(sed -n 's/^Exec=//p' "$f" | head -n1 | awk '{print $1}')
            base=$(basename "$exe")
            if [[ -n "$unit" ]] && command -v systemctl &>/dev/null; then
                systemctl --user mask "$unit" &>/dev/null \
                    && say "  masked $unit (undo: systemctl --user unmask $unit)" \
                    || warn "  could not mask $unit — uninstall $base instead"
            else
                warn "  $base has no systemd unit to mask — uninstall it to be rid of it"
            fi
            # it may already hold the name in this session; the mask only
            # stops the next activation, so drop the running one too
            if pgrep -x "$base" &>/dev/null; then
                pkill -x "$base" &>/dev/null || true
                say "  stopped the running $base"
            fi
        done
        say "  ${dim}restart Lucid (or log back in) so it claims the name${r}"
    else
        warn "  left alone — expect its notifications instead of Lucid's"
    fi
fi

# ------------------------------------------------------------------ hyprland

# binds, window rules, blur, animations and autostart. this is a whole session
# config, so an existing one is always backed up first and replacing it is a
# question - except when it is Lucid's own from an earlier run, which is just
# refreshed. kept out of the theming step: the modules read no palette, so
# --no-theming should not cost you the binds.
HYPR_DIR="$HOME/.config/hypr"
HYPR_LUA_INSTALLED=0

if [[ $WITH_HYPR -eq 1 ]]; then
    step "Setting up Hyprland"

    HAS_HYPR_CFG=0
    [[ -f "$HYPR_DIR/hyprland.lua" || -f "$HYPR_DIR/hyprland.conf" ]] && HAS_HYPR_CFG=1

    # a config we installed on an earlier run is not "someone else's config":
    # without telling them apart, a re-run asks to replace Lucid's own setup and
    # then tells you to add binds you already have
    HYPR_IS_LUCID=0
    if [[ -f "$HYPR_DIR/modules/binds.lua" ]] && grep -q 'qs ipc call' "$HYPR_DIR/modules/binds.lua" 2>/dev/null; then
        HYPR_IS_LUCID=1
    fi

    DO_HYPR=1
    if [[ $HYPR_IS_LUCID -eq 1 ]]; then
        say "  ${dim}already Lucid's — refreshing it${r}"
    elif [[ $HAS_HYPR_CFG -eq 1 && $HYPR_FORCE -eq 0 ]]; then
        say "  you already have a Hyprland config. Lucid's brings the binds,"
        say "  window rules, blur and animations, and yours is backed up first."
        if ! ask "  Replace it with Lucid's?"; then
            DO_HYPR=0
            say "  ${dim}left alone — re-run with --with-hypr to change your mind${r}"
        fi
    fi

    # the lua config only exists from Hyprland 0.55. an older one reads
    # hyprland.conf and ignores hyprland.lua, so replacing the config would
    # leave it with nothing but its own defaults - worth asking first.
    # `hyprctl version` prints "Hyprland 0.54.0 built from ..." with no v,
    # so the number is taken bare and compared as a number
    if [[ $DO_HYPR -eq 1 ]] && command -v hyprctl &>/dev/null; then
        HYPR_VER=$(hyprctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        if [[ -n "$HYPR_VER" ]]; then
            IFS=. read -r hv_major hv_minor _ <<< "$HYPR_VER"
            if (( hv_major == 0 && hv_minor < 55 )); then
                warn "  Hyprland $HYPR_VER predates the lua config (0.55+) — it will ignore hyprland.lua"
                if ! ask "  Install it anyway?"; then
                    DO_HYPR=0
                    say "  ${dim}left alone — update Hyprland, then re-run with --with-hypr${r}"
                fi
            fi
        fi
    fi

    if [[ $DO_HYPR -eq 1 ]]; then
        if [[ $HAS_HYPR_CFG -eq 1 ]]; then
            cp -r "$HYPR_DIR" "$HYPR_DIR.backup-$STAMP"
            say "  your hypr config -> $HYPR_DIR.backup-$STAMP"
        fi
        mkdir -p "$HYPR_DIR/modules" "$HYPR_DIR/scripts"
        cp "$SRC/support/hypr/hyprland.lua" "$HYPR_DIR/hyprland.lua"
        cp "$SRC/support/hypr/modules/"*.lua "$HYPR_DIR/modules/"
        install -m755 "$SRC/support/hypr/scripts/reload.sh" "$HYPR_DIR/scripts/reload.sh"
        # a hyprland.conf left beside hyprland.lua is ambiguous - Hyprland
        # reads one of them and you cannot tell which, so the install looks
        # like it did nothing. the full directory is already backed up above
        if [[ -f "$HYPR_DIR/hyprland.conf" ]]; then
            mv "$HYPR_DIR/hyprland.conf" "$HYPR_DIR/hyprland.conf.replaced-$STAMP"
            say "  hyprland.conf -> hyprland.conf.replaced-$STAMP (lua config wins now)"
            # a lua config cannot source a .conf, so whatever the old config
            # pulled in - hyprmod's hyprland-gui.conf, a file of your own -
            # stops being read here. name them, so the settings that vanish
            # with them are not a mystery: each needs a lua module in its
            # place (hyprmod adds require("hyprland-gui") when re-run)
            sourced=()
            while IFS= read -r f; do
                [[ -n "$f" ]] && sourced+=("$f")
            done < <(sed -nE 's/^[[:space:]]*source[[:space:]]*=[[:space:]]*//p' \
                        "$HYPR_DIR/hyprland.conf.replaced-$STAMP" \
                     | sed -E 's/[[:space:]]*#.*$//; s/[[:space:]]+$//' || true)
            if (( ${#sourced[@]} )); then
                warn "  it sourced ${#sourced[@]} file(s) that hyprland.lua will not read:"
                for f in "${sourced[@]}"; do
                    say "    $f"
                done
                say "  ${dim}a lua config cannot source .conf files. whatever wrote those needs a lua module instead — hyprmod: re-run it and accept its require(\"hyprland-gui\") line${r}"
            fi
        fi
        HYPR_LUA_INSTALLED=1
        say "  hyprland.lua + $(ls "$SRC/support/hypr/modules" | wc -l) modules -> $HYPR_DIR"
        say "  ${dim}binds, window rules, blur, animations and autostart come with it${r}"
        # a refresh replaces hyprland.lua whole, but a require added to it
        # since the last run - hyprmod's require("hyprland-gui"), a module
        # of your own - is not Lucid's to drop. those lines go back in,
        # after Lucid's, so what they set still wins. only on a refresh:
        # a config replaced on request was meant to go
        if [[ $HYPR_IS_LUCID -eq 1 && -f "$HYPR_DIR.backup-$STAMP/hyprland.lua" ]]; then
            carried=()
            while IFS= read -r line; do
                grep -qxF -- "$line" "$HYPR_DIR/hyprland.lua" && continue
                printf '%s\n' "${carried[@]:-}" | grep -qxF -- "$line" && continue
                carried+=("$line")
            done < <(grep -E '^[[:space:]]*(pcall[[:space:]]*\([[:space:]]*)?(require|dofile)[[:space:]]*[(,]' \
                        "$HYPR_DIR.backup-$STAMP/hyprland.lua" || true)
            if (( ${#carried[@]} )); then
                {
                    printf '\n-- kept by the Lucid installer: these were added to hyprland.lua after it was installed\n'
                    printf '%s\n' "${carried[@]}"
                } >> "$HYPR_DIR/hyprland.lua"
                say "  kept ${#carried[@]} require line(s) added to hyprland.lua since the last install"
            fi
        fi

        # modules/binds.lua binds from this list, which Settings -> Keybinds
        # edits. an existing one is yours and survives the refresh
        mkdir -p "$LUCID_DIR"
        if [[ -s "$LUCID_DIR/keybinds.json" ]]; then
            say "  ${dim}keeping existing $LUCID_DIR/keybinds.json${r}"
        else
            cp "$SRC/support/hypr/keybinds.json" "$LUCID_DIR/keybinds.json"
            say "  keybinds -> $LUCID_DIR/keybinds.json"
        fi

        # the binds shell out to these, so a missing one is a dead key rather
        # than a visible error. worth saying now, not after the first F-key
        for c in "${PICK_DEFAULT[files]:-thunar}" playerctl wpctl brightnessctl swappy grim; do
            command -v "$c" &>/dev/null || warn "  $c is missing — the binds that use it will do nothing"
        done

    fi
else
    step "Skipping the Hyprland config (--no-hypr)"
    say "  ${dim}the Lucid binds and window rules are not installed${r}"
fi

# the picker's defaults go on top of the binds just installed. with no
# keybinds.json (for example --no-hypr on a fresh machine) there is nothing
# to rewrite, and this returns silently
apply_app_binds

# ------------------------------------------------------------------ theming

if [[ $WITH_THEMING -eq 1 ]]; then
    step "Installing the theming layer"

    mkdir -p "$LUCID_DIR/themes" "$MATUGEN_DIR/templates" "$WALL_SCRIPT_DIR" "$HOME/.cache/quickshell"

    cp -r "$SRC/support/lucid/themes/." "$LUCID_DIR/themes/"
    install -m755 "$SRC/support/lucid/apply-theme.sh"      "$LUCID_DIR/apply-theme.sh"
    install -m755 "$SRC/support/lucid/render-templates.sh" "$LUCID_DIR/render-templates.sh"
    install -m755 "$SRC/support/lucid/templates.py"       "$LUCID_DIR/templates.py"
    install -m755 "$SRC/support/lucid/apply-colour.sh"    "$LUCID_DIR/apply-colour.sh"
    install -m755 "$SRC/support/lucid/wallpaper-colours.sh" "$LUCID_DIR/wallpaper-colours.sh"
    install -m755 "$SRC/support/lucid/wallpaper-mode.sh"  "$LUCID_DIR/wallpaper-mode.sh"
    install -m644 "$SRC/support/lucid/matugen-options.sh" "$LUCID_DIR/matugen-options.sh"
    install -m755 "$SRC/support/lucid/gen-pywal-palette.py" "$LUCID_DIR/gen-pywal-palette.py"
    install -m755 "$SRC/support/lucid/add-theme.py"        "$LUCID_DIR/add-theme.py"
    install -m755 "$SRC/support/lucid/scheme-gallery.py"   "$LUCID_DIR/scheme-gallery.py"
    install -m755 "$SRC/support/lucid/palette-edit.py"     "$LUCID_DIR/palette-edit.py"
    install -m755 "$SRC/support/lucid/gen-light-palette.py" "$LUCID_DIR/gen-light-palette.py"
    install -m755 "$SRC/support/lucid/app-palette.py"      "$LUCID_DIR/app-palette.py"
    install -m755 "$SRC/support/lucid/set-mode.sh"         "$LUCID_DIR/set-mode.sh"
    install -m755 "$SRC/support/lucid/sync-sddm.sh"        "$LUCID_DIR/sync-sddm.sh"
    install -m755 "$SRC/support/lucid/sync-starship.sh"    "$LUCID_DIR/sync-starship.sh"
    install -m755 "$SRC/support/lucid/setup-zen.sh"        "$LUCID_DIR/setup-zen.sh"
    mkdir -p "$LUCID_DIR/zen" && cp -r "$SRC/support/zen/." "$LUCID_DIR/zen/"
    install -m644 "$SRC/support/lucid/lucid_palette.py"    "$LUCID_DIR/lucid_palette.py"
    install -m755 "$SRC/support/wallpaper/set-wallpaper.sh" "$WALL_SCRIPT_DIR/set-wallpaper.sh"
    # rules you wrote are yours: only ever placed when there are none
    [[ -f "$LUCID_DIR/wallpaper-outputs.conf" ]] || install -m644 "$SRC/support/lucid/wallpaper-outputs.conf" "$LUCID_DIR/wallpaper-outputs.conf"
    # the sddm theme lives outside $HOME, so it is the one thing here that
    # needs root. skipped entirely when sddm is not installed, and it never
    # switches the active theme - that stays the user's call. root keeps the
    # theme; every account paints its own corner of it without a password
    if [[ -d /usr/share/sddm/themes ]]; then
        SDDM_THEME_DIR=/usr/share/sddm/themes/lucid
        # a fingerprint at the login screen needs two lines in sddm's pam
        # service, so it is asked for once and then kept on every re-run
        SDDM_FINGER=()
        if [[ -e /usr/lib/security/pam_fprintd.so ]]; then
            if grep -q '^# >>> lucid: fingerprint login' /etc/pam.d/sddm 2>/dev/null; then
                SDDM_FINGER=(--fingerprint)
            elif ask "  Let the login screen take a fingerprint too? (two lines in /etc/pam.d/sddm, backed up first)"; then
                SDDM_FINGER=(--fingerprint)
            fi
        fi
        if sudo bash "$SRC/support/sddm/install-theme.sh" "$SDDM_THEME_DIR" "${SDDM_FINGER[@]}"; then
            say "  sddm theme      -> $SDDM_THEME_DIR"
            # the theme no longer carries a shared wallpaper, so paint this
            # account's corner now rather than at its next login. it reads
            # the palette through qs, which needs the session's display
            if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
                "$LUCID_DIR/sync-sddm.sh" --missing &>/dev/null || true
            fi
            # /etc/sddm.conf outranks /etc/sddm.conf.d, so point at the file
            # that actually wins rather than at the tidier-looking drop-in
            say "    enable it with: Current=lucid under [Theme] in /etc/sddm.conf"
        else
            warn "could not install the sddm theme (needs sudo); skipping"
        fi
    fi

    say "  theme palettes  -> $LUCID_DIR/themes"
    say "  theme scripts   -> $LUCID_DIR"
    say "  wallpaper hook  -> $WALL_SCRIPT_DIR/set-wallpaper.sh"

    cp -r "$SRC/support/matugen/templates/." "$MATUGEN_DIR/templates/"
    say "  matugen templates -> $MATUGEN_DIR/templates/"

    MATUGEN_CFG="$MATUGEN_DIR/config.toml"
    [[ -f "$MATUGEN_CFG" ]] && cp "$MATUGEN_CFG" "$MATUGEN_CFG.backup-$STAMP"
    [[ -f "$MATUGEN_CFG" ]] || printf '[config]\n' > "$MATUGEN_CFG"

    TPL='~/.config/matugen/templates'
    MG_ADDED=(); MG_KEPT=(); MG_SKIPPED=()

    # older installs gave starship a matugen template, which wrote the whole
    # starship.toml and so replaced any prompt the user had made. only its
    # palette is repainted now (sync-starship.sh), so Lucid's own block goes;
    # a starship block pointing anywhere else is the user's and stays
    if grep -q '^\[templates\.starship\]' "$MATUGEN_CFG"; then
        awk '
            function flush() { if (!(inblk && lucid)) printf "%s", blk; blk = ""; inblk = 0; lucid = 0 }
            /^\[/ { flush(); if ($0 ~ /^\[templates\.starship\]/) inblk = 1 }
            { blk = blk $0 "\n"; if (inblk && $0 ~ /starship-colors\.toml/) lucid = 1 }
            END { flush() }
        ' "$MATUGEN_CFG" > "$MATUGEN_CFG.lucid-tmp" && cat "$MATUGEN_CFG.lucid-tmp" > "$MATUGEN_CFG"
        rm -f "$MATUGEN_CFG.lucid-tmp"
    fi

    # firefox and zen keep their chrome css inside a generated profile dir, so
    # the path has to be discovered rather than assumed. zen's comes from its
    # installs.ini: an empty *.Default* folder it never opens often sorts first
    FF_PROFILE=$(find "$HOME/.mozilla/firefox" -maxdepth 1 -type d -name '*.default-release' 2>/dev/null | head -1 || true)
    ZEN_PROFILE=$("$LUCID_DIR/setup-zen.sh" profile 2>/dev/null || true)

    # zen's colours used to be rendered straight into userChrome.css, which
    # replaced anything the user kept there, and sometimes into the wrong
    # profile. Lucid's block now writes lucid-zen.css in the profile zen
    # starts with, and userChrome.css imports it (setup-zen.sh)
    if grep -q '^\[templates\.zen\]' "$MATUGEN_CFG"; then
        LUCID_ZEN_OUT="${ZEN_PROFILE:+$ZEN_PROFILE/chrome/lucid-zen.css}" awk '
            function flush() {
                if (inblk && lucid) {
                    if (ENVIRON["LUCID_ZEN_OUT"] != "")
                        sub(/\noutput_path *= *[^\n]*/, "\noutput_path = \047" ENVIRON["LUCID_ZEN_OUT"] "\047", blk)
                    else
                        sub(/\/chrome\/userChrome\.css/, "/chrome/lucid-zen.css", blk)
                }
                printf "%s", blk; blk = ""; inblk = 0; lucid = 0
            }
            /^\[/ { flush(); if ($0 ~ /^\[templates\.zen\]/) inblk = 1 }
            { blk = blk $0 "\n"; if (inblk && $0 ~ /zen-userchrome\.css/) lucid = 1 }
            END { flush() }
        ' "$MATUGEN_CFG" > "$MATUGEN_CFG.lucid-tmp" && cat "$MATUGEN_CFG.lucid-tmp" > "$MATUGEN_CFG"
        rm -f "$MATUGEN_CFG.lucid-tmp"
    fi

    # a block is only added when the app it themes is actually present, so
    # matugen never writes colours into a config directory that isn't there.
    # an existing block is always left alone - this config is the user's.
    add_template() {
        local name=$1 input=$2 output=$3 guard=${4:-always} hook=${5:-}
        case "$guard" in
            always) ;;
            dir:*)  [[ -d "${guard#dir:}" ]] || { MG_SKIPPED+=("$name"); return 0; } ;;
            file:*) [[ -f "${guard#file:}" ]] || { MG_SKIPPED+=("$name"); return 0; } ;;
            cmd:*)  command -v "${guard#cmd:}" &>/dev/null || { MG_SKIPPED+=("$name"); return 0; } ;;
        esac
        if grep -q "^\[templates\.$name\]" "$MATUGEN_CFG"; then
            MG_KEPT+=("$name"); return 0
        fi
        mkdir -p "$(dirname "${output/#\~/$HOME}")"
        {
            printf '\n[templates.%s]\n' "$name"
            printf "input_path = '%s'\n" "$input"
            printf "output_path = '%s'\n" "$output"
            [[ -n "$hook" ]] && printf "post_hook = '%s'\n" "$hook" || true
        } >> "$MATUGEN_CFG"
        MG_ADDED+=("$name")
    }

    add_template quickshell     "$TPL/quickshell-colors.json"  '~/.cache/quickshell/matugen.json'
    add_template hyprland       "$TPL/hyprland-colors.lua"     '~/.config/hypr/colors.conf'    "dir:$HOME/.config/hypr"
    add_template kitty          "$TPL/kitty.conf"              '~/.config/kitty/matugen-colors.conf' "cmd:kitty" 'killall -SIGUSR1 kitty 2>/dev/null || true'
    add_template foot           "$TPL/foot.ini"                '~/.config/foot/lucid-colors.ini' "cmd:foot"
    # no dir: guard on these two. gtk only creates ~/.config/gtk-{3,4}.0 once
    # an app writes a setting there, so on a fresh machine the guard skipped
    # both templates, matugen never wrote colors.css, and nautilus kept its
    # stock colours forever. add_template creates the directory itself.
    add_template gtk3           "$TPL/gtk-colors.css"          '~/.config/gtk-3.0/colors.css'
    add_template gtk4           "$TPL/gtk-colors.css"          '~/.config/gtk-4.0/colors.css'
    add_template rofi           "$TPL/rofi-colors.rasi"        '~/.config/rofi/colors.rasi'    "dir:$HOME/.config/rofi"
    add_template waybar         "$TPL/colors.css"              '~/.config/waybar/colors.css'   "dir:$HOME/.config/waybar"
    add_template swaync         "$TPL/colors.css"              '~/.config/swaync/colors.css'   "dir:$HOME/.config/swaync"
    add_template wlogout        "$TPL/colors.css"              '~/.config/wlogout/colors.css'  "dir:$HOME/.config/wlogout"
    add_template ags            "$TPL/ags-colors.scss"         '~/.config/ags/style/_colors.scss' "dir:$HOME/.config/ags"
    add_template vesktop        "$TPL/midnight-discord.css"    '~/.config/vesktop/themes/midnight-discord.css' "dir:$HOME/.config/vesktop"
    add_template pywalfox       "$TPL/pywalfox-colors.json"    '~/.cache/wal/colors.json'      "cmd:pywalfox" 'pywalfox update'
    add_template steam-material "$TPL/steam-material.css"      '~/.local/share/Steam/millennium/themes/Material-Theme/css/main/colors/matugen.css' \
                                "dir:$HOME/.local/share/Steam/millennium/themes/Material-Theme"
    # Qt widget apps take their palette from qt6ct, the platform theme
    # modules/env.lua sets. KDE apps then lay a KDE colour scheme over it, so
    # they get one too - both are pointed at below. qt6ct watches its own
    # folder but not colors/, so the hook touches qt6ct.conf for open apps
    add_template qt6ct          "$TPL/qt6ct-colors.conf"       '~/.config/qt6ct/colors/lucid.conf' "cmd:qt6ct" \
                                'touch -c ~/.config/qt6ct/qt6ct.conf'
    add_template kde            "$TPL/kde-colors.colors"       '~/.local/share/color-schemes/Lucid.colors' "cmd:qt6ct"

    if [[ -n "$FF_PROFILE" ]]; then
        add_template firefox-website-colors "$TPL/firefox-colors.css" "$FF_PROFILE/chrome/colors.css"
    else
        MG_SKIPPED+=(firefox-website-colors)
    fi
    if [[ -n "$ZEN_PROFILE" ]]; then
        add_template zen "$TPL/zen-userchrome.css" "$ZEN_PROFILE/chrome/lucid-zen.css"
        add_template zen-sites "$TPL/zen-sites.css" "$ZEN_PROFILE/chrome/lucid-sites.css"
        "$LUCID_DIR/setup-zen.sh" install || warn "could not point zen's userChrome.css at Lucid's colours"
        # colours that change while zen runs need fx-autoconfig's loader in
        # zen's own folder. it runs whatever lands in the profile's chrome/JS
        # with the browser's rights, so it is asked for
        "$LUCID_DIR/setup-zen.sh" program --check && ZEN_LOADER=0 || ZEN_LOADER=$?
        if (( ZEN_LOADER == 1 )) \
            && ask "  Let Zen change colours while it runs? (puts fx-autoconfig's loader in Zen's folder, needs sudo)"; then
            "$LUCID_DIR/setup-zen.sh" program || warn "could not add zen's loader; its colours change when it restarts"
        fi
    else
        MG_SKIPPED+=(zen)
    fi

    (( ${#MG_ADDED[@]} ))   && say "  matugen added:   ${MG_ADDED[*]}"                                || true
    (( ${#MG_KEPT[@]} ))    && say "  ${dim}matugen kept:    ${MG_KEPT[*]}${r}"                       || true
    (( ${#MG_SKIPPED[@]} )) && say "  ${dim}matugen skipped: ${MG_SKIPPED[*]} (not installed)${r}"    || true

    # put keys under [section] of an ini file, creating the section - or the
    # file - when it isn't there
    ini_add_keys() {
        local file=$1 section=$2 keys=$3
        mkdir -p "$(dirname "$file")"
        if [[ ! -f "$file" ]]; then
            printf '[%s]\n%s\n' "$section" "$keys" > "$file"
        elif grep -qxF "[$section]" "$file"; then
            awk -v s="[$section]" -v k="$keys" '{ print } $0 == s { print k }' "$file" > "$file.lucid-tmp" \
                && cat "$file.lucid-tmp" > "$file"
            rm -f "$file.lucid-tmp"
        else
            printf '\n[%s]\n%s\n' "$section" "$keys" >> "$file"
        fi
    }

    # with no palette chosen in qt6ct, Qt apps (Prism Launcher, qt6ct itself...)
    # get Qt's stock light one whatever the theme. a palette already picked
    # there is the user's and stays
    QT6CT_CFG="$HOME/.config/qt6ct/qt6ct.conf"
    if command -v qt6ct &>/dev/null && grep -q '^\[templates\.qt6ct\]' "$MATUGEN_CFG"; then
        if grep -qE '^(custom_palette|color_scheme_path)=' "$QT6CT_CFG" 2>/dev/null; then
            say "  ${dim}qt6ct already has a palette${r}"
        else
            ini_add_keys "$QT6CT_CFG" Appearance \
                "color_scheme_path=$HOME/.config/qt6ct/colors/lucid.conf"$'\n'"custom_palette=true"
            say "  qt6ct now uses the theme's palette"
        fi
    fi

    # outside Plasma, a KDE app (Dolphin, Kate, Okular...) with no colour scheme
    # named in kdeglobals swaps the qt6ct palette for Breeze Light or Dark as it
    # starts, so name Lucid's. one already named - by Plasma under [General] or
    # by the user - stays
    KDEGLOBALS="$HOME/.config/kdeglobals"
    if command -v qt6ct &>/dev/null && grep -q '^\[templates\.kde\]' "$MATUGEN_CFG"; then
        if grep -q '^ColorScheme=' "$KDEGLOBALS" 2>/dev/null; then
            say "  ${dim}kdeglobals already names a colour scheme${r}"
        else
            ini_add_keys "$KDEGLOBALS" UiSettings "ColorScheme=Lucid"
            say "  KDE apps now use the theme's colour scheme"
        fi
    fi

    # GTK apps - Nautilus included - only read colors.css if gtk.css imports it
    for gtkver in 3.0 4.0; do
        gtkdir="$HOME/.config/gtk-$gtkver"
        mkdir -p "$gtkdir"
        if [[ -f "$gtkdir/gtk.css" ]] && grep -q "colors.css" "$gtkdir/gtk.css"; then
            say "  ${dim}gtk-$gtkver already imports colors.css${r}"
        else
            [[ -f "$gtkdir/gtk.css" ]] && cp "$gtkdir/gtk.css" "$gtkdir/gtk.css.backup-$STAMP"
            printf "@import url('colors.css');\n" >> "$gtkdir/gtk.css"
            say "  gtk-$gtkver now imports colors.css"
        fi
    done

    # --- the look: fastfetch, foot and kitty ------------------------------
    # a checklist rather than one blanket question: each item only touches the
    # file it names, and is backed up first because the user owns it
    if [[ $WITH_LOOK -eq 1 ]]; then
        # inline checkbox picker, drawn in place like pick_apps. nothing starts
        # ticked unless that config is already Lucid's
        pick_look() {
            local -a label=() note=()
            local -A on=()
            local cur=0 lines=0 i key k2 k3 mark skip="" quit="" row changed=0
            local foot_ini="$HOME/.config/foot/foot.ini"

            # only an installed tool gets a row; nothing installed, nothing to ask
            if command -v fastfetch &>/dev/null; then
                i=${#label[@]}
                label+=(Fastfetch); note+=("support/look/fastfetch.jsonc")
                if [[ -f "$HOME/.config/fastfetch/config.jsonc" ]] \
                    && cmp -s "$HOME/.config/fastfetch/config.jsonc" "$SRC/support/look/fastfetch.jsonc"; then
                    on[$i]=1
                fi
            fi
            if command -v foot &>/dev/null; then
                i=${#label[@]}
                label+=(foot); note+=("palette include")
                if [[ -f "$foot_ini" ]] && grep -q 'lucid-colors.ini' "$foot_ini"; then
                    on[$i]=1
                fi
            fi
            if command -v kitty &>/dev/null; then
                i=${#label[@]}
                label+=(kitty); note+=("config, matugen include, glass include, shell fish")
                if [[ -f "$HOME/.config/kitty/kitty.conf" ]] \
                    && cmp -s "$HOME/.config/kitty/kitty.conf" "$SRC/support/look/kitty.conf"; then
                    on[$i]=1
                fi
            fi

            LOOK_SELECTED=()
            if (( ${#label[@]} == 0 )); then
                printf '  look: nothing installed to style\n'
                return 0
            fi

            # Ctrl-C must not leave the terminal with a hidden cursor, reverse
            # video or a muted tty
            trap 'stty echo 2>/dev/null || true; printf "\e[0m\e[?25h"; exit 130' INT TERM
            printf '\e[?25l'
            # echo stays off for the whole picker: between reads the tty would
            # print keys pressed while the redraw runs all over the list
            stty -echo 2>/dev/null || true

            lines=0
            # one printf per row and every row is cut to the terminal width, so
            # a row is always exactly one visual row and counting back cannot drift.
            line() {
                local st="$1" row="$2"
                row=${row:0:cols-1}
                printf '%s%s\e[0m\e[K\n' "$st" "$row"
                lines=$((lines + 1))
            }
            draw() {
                cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
                if (( lines > 0 )); then printf '\e[%dA' "$lines"; fi
                lines=0
                line "$b" "Apply your look"
                line "$dim" "optional - blur and wallpaper colours still apply"
                for i in "${!label[@]}"; do
                    mark="[ ]"
                    if [[ -n ${on[$i]:-} ]]; then mark="[x]"; fi
                    printf -v row ' %s %-9s%s' "$mark" "${label[i]}" "${note[i]:+ ${note[i]}}"
                    if [[ $i -eq $cur ]]; then
                        line $'\e[7m' "$row"
                    else
                        line "" "$row"
                    fi
                done
                line "" ""
                line "$dim" "  up/down or j/k move   space toggle   enter apply   s skip   q quit"
            }

            draw
            while :; do
                changed=0
                IFS= read -rsn1 key || key=""
                if [[ -z $key || $key == $'\n' ]]; then break; fi
                if [[ $key == $'\e' ]]; then
                    IFS= read -rsn1 -t 0.02 k2 || k2=""
                    if [[ $k2 == '[' ]]; then
                        IFS= read -rsn1 -t 0.02 k3 || k3=""
                        case "$k3" in
                            A) if (( cur > 0 )); then cur=$((cur - 1)); changed=1; fi ;;
                            B) if (( cur < ${#label[@]} - 1 )); then cur=$((cur + 1)); changed=1; fi ;;
                        esac
                    fi
                else
                    case "$key" in
                        s) skip=1; break ;;
                        q) quit=1; break ;;
                        k) if (( cur > 0 )); then cur=$((cur - 1)); changed=1; fi ;;
                        j) if (( cur < ${#label[@]} - 1 )); then cur=$((cur + 1)); changed=1; fi ;;
                        ' ')
                            if [[ -n ${on[$cur]:-} ]]; then unset "on[$cur]"; else on[$cur]=1; fi
                            changed=1
                            ;;
                    esac
                fi
                if (( changed )); then draw; fi
            done

            # one short drain of keys still queued, so a held key cannot spill
            # onto the next prompt
            while IFS= read -rsn1 -t 0.01 _; do :; done
            trap - INT TERM
            stty echo 2>/dev/null || true
            printf '\e[0m\e[?25h\n'

            if [[ -n $quit ]]; then printf 'stopped.\n'; exit 1; fi

            LOOK_SELECTED=()
            if [[ -n $skip ]]; then
                printf '  look: skipped\n'
                return 0
            fi
            for i in "${!label[@]}"; do
                if [[ -n ${on[$i]:-} ]]; then LOOK_SELECTED[${label[i],,}]=1; fi
            done
            local picked="none"
            (( ${#LOOK_SELECTED[@]} )) && picked="${!LOOK_SELECTED[*]}"
            printf '  look: %s\n' "$picked"
        }

        LOOK_SELECTED=()
        if [[ $ASSUME_YES -eq 0 && -t 0 ]]; then pick_look; fi

        # fastfetch - its keys, title and logo are ANSI 32 (color2), which
        # every Lucid theme paints the primary, so it follows the theme. a
        # config of your own stays as it is
        if [[ -n ${LOOK_SELECTED[fastfetch]:-} ]]; then
            FASTFETCH_CFG="$HOME/.config/fastfetch/config.jsonc"
            if [[ ! -f "$FASTFETCH_CFG" ]]; then
                mkdir -p "$(dirname "$FASTFETCH_CFG")"
                cp "$SRC/support/look/fastfetch.jsonc" "$FASTFETCH_CFG"
                say "  fastfetch config -> ~/.config/fastfetch/config.jsonc"
            elif cmp -s "$FASTFETCH_CFG" "$SRC/support/look/fastfetch.jsonc"; then
                say "  ${dim}fastfetch config is already Lucid's${r}"
            else
                say "  ${dim}keeping your fastfetch config; Lucid's is support/look/fastfetch.jsonc${r}"
            fi
        fi

        # foot - only the include; the palette itself is a matugen template
        if [[ -n ${LOOK_SELECTED[foot]:-} ]]; then
            FOOT_INI="$HOME/.config/foot/foot.ini"
            if [[ ! -f "$FOOT_INI" ]]; then
                mkdir -p "$(dirname "$FOOT_INI")"
                printf '# Lucid — foot\n' > "$FOOT_INI"
                say "  foot.ini -> ~/.config/foot/foot.ini"
            else
                cp "$FOOT_INI" "$FOOT_INI.backup-$STAMP"
                say "  your foot.ini -> foot.ini.backup-$STAMP"
            fi
            if grep -q 'include=~/.config/foot/lucid-colors.ini' "$FOOT_INI"; then
                say "  ${dim}foot.ini already includes lucid-colors.ini${r}"
            else
                printf '\n# added by Lucid — colours follow the active theme\ninclude=~/.config/foot/lucid-colors.ini\n' \
                    >> "$FOOT_INI"
                say "  foot.ini now includes lucid-colors.ini"
            fi
        fi

        if [[ -n ${LOOK_SELECTED[kitty]:-} ]]; then
            # kitty - the include is what makes matugen's colours apply at all
            KITTY_CFG="$HOME/.config/kitty/kitty.conf"
            KITTY_EXISTED=0; [[ -f "$KITTY_CFG" ]] && KITTY_EXISTED=1

            # a kitty.conf an earlier install shipped, with nothing of the user's
            # in it: every setting is one Lucid wrote, then or now. that copy is
            # swapped for the current one; any other is theirs and only gets the
            # includes below
            kitty_is_lucids() {
                [[ $(head -n1 "$1") == "# Lucid — kitty" ]] || return 1
                local ours extra
                ours=$(grep -vE '^[[:space:]]*(#|$)' "$SRC/support/look/kitty.conf"; printf '%s\n' "background_opacity 0.7")
                extra=$(grep -vE '^[[:space:]]*(#|$)' "$1" | grep -vxF -e "$ours" || true)
                [[ -z $extra ]]
            }
            if [[ -f "$KITTY_CFG" ]] && ! cmp -s "$KITTY_CFG" "$SRC/support/look/kitty.conf" && kitty_is_lucids "$KITTY_CFG"; then
                cp "$KITTY_CFG" "$KITTY_CFG.backup-$STAMP"
                cp "$SRC/support/look/kitty.conf" "$KITTY_CFG"
                say "  kitty.conf -> the current Lucid one (the old copy: kitty.conf.backup-$STAMP)"
            fi

            if [[ -f "$HOME/.config/kitty/kitty.conf" ]]; then
                if grep -q "matugen-colors.conf" "$HOME/.config/kitty/kitty.conf"; then
                    say "  ${dim}kitty.conf already includes matugen-colors.conf${r}"
                else
                    cp "$HOME/.config/kitty/kitty.conf" "$HOME/.config/kitty/kitty.conf.backup-$STAMP"
                    printf '\n# added by Lucid — colours follow the active theme\ninclude ./matugen-colors.conf\n' \
                        >> "$HOME/.config/kitty/kitty.conf"
                    say "  kitty.conf now includes matugen-colors.conf"
                fi
            else
                mkdir -p "$HOME/.config/kitty"
                cp "$SRC/support/look/kitty.conf" "$HOME/.config/kitty/kitty.conf"
                say "  kitty.conf -> ~/.config/kitty/kitty.conf"
            fi

            # background_opacity follows the Glass slider, out of a file the shell
            # rewrites. seed it first: kitty warns about an include it cannot find,
            # and the shell only writes once the value differs from what is there
            if [[ ! -f "$HOME/.config/kitty/lucid-glass.conf" ]]; then
                printf '# generated by lucid settings\ndynamic_background_opacity yes\nbackground_opacity 1.00\n' \
                    > "$HOME/.config/kitty/lucid-glass.conf"
                say "  lucid-glass.conf -> ~/.config/kitty/lucid-glass.conf"
            fi
            if grep -q "lucid-glass.conf" "$KITTY_CFG"; then
                say "  ${dim}kitty.conf already includes lucid-glass.conf${r}"
            else
                [[ $KITTY_EXISTED -eq 1 && ! -f "$KITTY_CFG.backup-$STAMP" ]] \
                    && cp "$KITTY_CFG" "$KITTY_CFG.backup-$STAMP"
                printf '\n# added by Lucid — opacity follows the Glass slider\ninclude ./lucid-glass.conf\n' \
                    >> "$KITTY_CFG"
                say "  kitty.conf now follows the Glass slider"
            fi

            # kitty opens fish rather than the login shell. only wired when fish is
            # really there: kitty fails to open a window at all on a shell it cannot
            # exec, and that reads as "the terminal keybind is broken"
            if command -v fish &>/dev/null; then
                if grep -qE '^[[:space:]]*shell[[:space:]]+' "$KITTY_CFG"; then
                    say "  ${dim}kitty.conf already sets a shell${r}"
                else
                    [[ $KITTY_EXISTED -eq 1 && ! -f "$KITTY_CFG.backup-$STAMP" ]] \
                        && cp "$KITTY_CFG" "$KITTY_CFG.backup-$STAMP"
                    printf '\n# added by Lucid\nshell fish\n' >> "$KITTY_CFG"
                    say "  kitty.conf now opens fish"
                fi
            else
                sed -i '/^# kitty opens fish rather than the login shell$/d; /^shell fish$/d' "$KITTY_CFG"
                warn "  fish is not installed — kitty will use your login shell"
            fi
        fi

        # fastfetch's logo and kitty.conf are drawn with nerd font glyphs;
        # without the font they render as replacement boxes
        if [[ -n ${LOOK_SELECTED[fastfetch]:-}${LOOK_SELECTED[kitty]:-} ]]; then
            fc-list 2>/dev/null | grep -i 'JetBrainsMono Nerd Font' >/dev/null \
                || warn "  JetBrainsMono Nerd Font is missing — the look will show boxes"
        fi

        # hyprland blur - skipped when the lua config went in above, since its
        # decorations module already carries the same blur
        if [[ $HYPR_LUA_INSTALLED -eq 1 ]]; then
            say "  ${dim}blur comes from modules/decorations.lua${r}"
        elif [[ -f "$HYPR_DIR/hyprland.lua" ]]; then
            mkdir -p "$HYPR_DIR/modules"
            cp "$SRC/support/look/lucid-look.lua" "$HYPR_DIR/modules/lucid-look.lua"
            # per-app glass rides along: Settings > Glass writes lucid-glass.lua
            # and this is the module that reads it
            cp "$SRC/support/hypr/modules/glass.lua" "$HYPR_DIR/modules/glass.lua"
            # and so do the options Settings > Windows sets, in lucid-settings.lua
            cp "$SRC/support/hypr/modules/settings.lua" "$HYPR_DIR/modules/settings.lua"
            # and the apps and variables Settings > Startup keeps, in lucid-startup.lua
            cp "$SRC/support/hypr/modules/startup.lua" "$HYPR_DIR/modules/startup.lua"
            if grep -q 'require("modules.lucid-look")' "$HYPR_DIR/hyprland.lua"; then
                say "  ${dim}hyprland.lua already requires modules.lucid-look${r}"
            else
                cp "$HYPR_DIR/hyprland.lua" "$HYPR_DIR/hyprland.lua.backup-$STAMP"
                printf '\nrequire("modules.lucid-look")\n' >> "$HYPR_DIR/hyprland.lua"
                say "  hyprland.lua now requires modules.lucid-look"
            fi
            if grep -q 'require("modules.glass")' "$HYPR_DIR/hyprland.lua"; then
                say "  ${dim}hyprland.lua already requires modules.glass${r}"
            else
                [[ -f "$HYPR_DIR/hyprland.lua.backup-$STAMP" ]] \
                    || cp "$HYPR_DIR/hyprland.lua" "$HYPR_DIR/hyprland.lua.backup-$STAMP"
                printf '\nrequire("modules.glass")\n' >> "$HYPR_DIR/hyprland.lua"
                say "  hyprland.lua now requires modules.glass"
            fi
            if grep -q 'require("modules.settings")' "$HYPR_DIR/hyprland.lua"; then
                say "  ${dim}hyprland.lua already requires modules.settings${r}"
            else
                [[ -f "$HYPR_DIR/hyprland.lua.backup-$STAMP" ]] \
                    || cp "$HYPR_DIR/hyprland.lua" "$HYPR_DIR/hyprland.lua.backup-$STAMP"
                printf '\nrequire("modules.settings")\n' >> "$HYPR_DIR/hyprland.lua"
                say "  hyprland.lua now requires modules.settings"
            fi
            if grep -q 'require("modules.startup")' "$HYPR_DIR/hyprland.lua"; then
                say "  ${dim}hyprland.lua already requires modules.startup${r}"
            else
                [[ -f "$HYPR_DIR/hyprland.lua.backup-$STAMP" ]] \
                    || cp "$HYPR_DIR/hyprland.lua" "$HYPR_DIR/hyprland.lua.backup-$STAMP"
                printf '\nrequire("modules.startup")\n' >> "$HYPR_DIR/hyprland.lua"
                say "  hyprland.lua now requires modules.startup"
            fi
        elif [[ -f "$HYPR_DIR/hyprland.conf" ]]; then
            cp "$SRC/support/look/lucid-look.conf" "$HYPR_DIR/lucid-look.conf"
            if grep -q "lucid-look.conf" "$HYPR_DIR/hyprland.conf"; then
                say "  ${dim}hyprland.conf already sources lucid-look.conf${r}"
            else
                cp "$HYPR_DIR/hyprland.conf" "$HYPR_DIR/hyprland.conf.backup-$STAMP"
                printf '\nsource = ~/.config/hypr/lucid-look.conf\n' >> "$HYPR_DIR/hyprland.conf"
                say "  hyprland.conf now sources lucid-look.conf"
            fi
        else
            mkdir -p "$HYPR_DIR"
            cp "$SRC/support/look/lucid-look.conf" "$HYPR_DIR/lucid-look.conf"
            warn "  no hyprland config found — source lucid-look.conf yourself"
        fi
    fi

    # first-run palette, so the shell has colours before any wallpaper is set
    [[ -f "$HOME/.cache/current_theme" ]] || printf 'matugen' > "$HOME/.cache/current_theme"
    if [[ ! -s "$HOME/.cache/quickshell/matugen.json" ]]; then
        cp "$SRC/support/lucid/themes/nord/quickshell.json" "$HOME/.cache/quickshell/matugen.json"
        say "  seeded a starter palette (nord) — pick a theme in Settings to change it"
    fi
else
    step "Skipping the theming layer (--no-theming)"
    say "  the theme picker and wallpaper strip will not work until it is installed"
fi

# -------------------------------------------------------------- wallpapers

# one folder per theme, which is where the wallpaper strip looks:
# ~/Pictures/wallpapers/<theme>. yours are never overwritten or removed
PICTURES_DIR="$HOME/Pictures/wallpapers"
if [[ $WITH_WALLPAPERS -eq 1 && -d "$SRC/wallpapers" ]]; then
    step "Installing the wallpapers"

    WALL_NEW=0
    WALL_KEPT=0
    for dir in "$SRC"/wallpapers/*/; do
        [[ -d "$dir" ]] || continue
        theme="$(basename "$dir")"
        mkdir -p "$PICTURES_DIR/$theme"
        for pic in "$dir"*; do
            [[ -f "$pic" ]] || continue
            dest="$PICTURES_DIR/$theme/$(basename "$pic")"
            if [[ -e "$dest" ]]; then
                WALL_KEPT=$((WALL_KEPT + 1))
            else
                cp "$pic" "$dest"
                WALL_NEW=$((WALL_NEW + 1))
            fi
        done
    done

    say "  $WALL_NEW wallpapers -> $PICTURES_DIR"
    [[ $WALL_KEPT -gt 0 ]] && say "  ${dim}$WALL_KEPT were already there, left as they are${r}"
    say "  ${dim}the strip shows the folder for the theme you are on; SUPER+B opens it${r}"
elif [[ $WITH_WALLPAPERS -eq 0 ]]; then
    step "Skipping the wallpapers (--no-wallpapers)"
    say "  ${dim}$PICTURES_DIR is left alone; the strip shows whatever is in it${r}"
fi

# ---------------------------------------------------------------------- done

step "Done"

# a running instance is still on the old files, so offer the restart that
# actually puts the new version on screen.
# the path alone is not enough: with nothing running, `qs list` says
# "No running instances for <path>", which the path matches. the field only
# a real instance has is what to look for.
# no grep -q here: it would close the pipe, and pipefail would then read the
# producer's SIGPIPE as "not running". the in-shell updater (LUCID_UPDATER)
# asks about the restart itself, once the install has finished
if [[ -z "${LUCID_UPDATER:-}" ]] && qs list 2>/dev/null | grep -F "Config path: $SHELL_DIR/shell.qml" >/dev/null; then
    if ask "  Lucid is running on the old files. Restart it now?"; then
        qs kill -p "$SHELL_DIR" 2>/dev/null || true
        sleep 1
        # through the launcher, as autostart does, so the new instance gets
        # the same render backend and driver choice as one started at login
        if [[ -x "$LUCID_DIR/launch-shell.sh" ]]; then
            (setsid "$LUCID_DIR/launch-shell.sh" -d >/dev/null 2>&1 &) || true
        else
            (setsid qs -d >/dev/null 2>&1 &) || true
        fi
        say "  restarted"
    fi
fi

cat <<EOF

  ${b}Lucid $VERSION${r} is installed.

  Start it:      ${b}qs${r}
  Settings:      ${b}qs ipc call -- settings open${r}

EOF

if [[ $HYPR_LUA_INSTALLED -eq 1 ]]; then
    cat <<EOF
  Hyprland is configured: modules/binds.lua carries the binds, the window
  and layer rules are in place, and modules/autostart.lua starts the shell
  on login.

    SUPER            launcher        SUPER+Tab    workspaces
    SUPER+I          settings        SUPER+T      theme picker
    SUPER+period     emoji           SUPER+B      wallpaper
    SUPER+P          commands        SUPER+E      files
    SUPER+C          close window    SUPER+V      float
    SUPER+Return     terminal        SUPER+W      Zen browser
    SUPER+Escape     session         F10          lock
    CTRL+ALT+R       reload hypr     CTRL+ALT+TAB switch windows

  Special workspaces slide over whatever you are on; the same keys hide them.
  SUPER+Shift plus the same key moves the focused window there:

    SUPER+S          scratchpad      SUPER+Shift+S  move to scratchpad
    SUPER+A          music           SUPER+Shift+A  move to music
    SUPER+D          comms (show)    SUPER+Shift+D  move to comms
    SUPER+R          to-do           SUPER+Shift+R  move to to-do
    SUPER+X          system monitor  SUPER+Shift+X  move to system monitor

  ${b}The new binds are not live yet${r} — run ${b}hyprctl reload${r}, or log out
  and back in to pick up the autostart too.

EOF
else
    cat <<EOF
  Autostart:     add ${b}exec-once = qs${r} to your Hyprland config

  Suggested Hyprland binds:

    bind = SUPER, SPACE,  exec, qs ipc call -- launcher toggle
    bind = SUPER, E,      exec, qs ipc call -- moji toggle
    bind = SUPER, L,      exec, qs ipc call -- lock lock
    bind = SUPER, S,      exec, qs ipc call -- snap toggle
    bind = SUPER, comma,  exec, qs ipc call -- settings open

  Keep the double dash: it is required whenever a call takes an argument.
  Or run ${b}./install.sh --with-hypr${r} to take Lucid's config wholesale.

EOF
fi

if [[ $DEPS_OK -eq 0 ]]; then
    warn "some dependencies are missing — the shell is installed, but the"
    warn "features they back will not work until you install them."
fi
