#!/usr/bin/env bash
# Ghost Browser installer (Debian, Ubuntu, Linux Mint and their relatives; 64-bit Intel/AMD only).
#
#   bash install.sh              install or update, then a guided VPN setup
#   bash install.sh --dry-run    show what would happen; changes nothing, needs no password
#   bash install.sh --no-setup   install or update only, no VPN setup questions
#   bash install.sh --uninstall  remove the launcher, menu entry, desktop icon and menu override
#
# Run it as your normal user in a normal terminal; it asks for your password (sudo) only for the system steps.
# What it does, in order:
#   1. checks this system: Debian-family, amd64, a terminal, not root, Ghost Browser not running;
#   2. refreshes the package lists, and installs curl, gpg and CA certificates if missing (needed for the
#      checked downloads);
#   3. Mullvad Browser from Mullvad's own apt repository. Mullvad's signing key is checked against its
#      published fingerprint, and what gets installed is gpg's own clean copy of that one key, never the
#      downloaded file. A Mullvad package source you already have is used only if it is byte for byte the
#      one line this installer writes, root-owned, with exactly that key; anything else, or any warning from
#      apt about your sources, is refused (you are told what to do). This is checked before apt first runs
#      as root. The package must come from Mullvad's repository only, as root's apt sees it.
#      Skipped if Mullvad Browser is already installed;
#   4. vopono 1.0.2 from its GitHub release, checked against a pinned SHA-256 before it is installed, without
#      its optional extras (they include proxy and VPN services Ghost Browser does not use).
#      Ghost Browser's file checks copy this exact vopono version's config reader, so the version is pinned;
#   5. the other tools Ghost Browser calls (WireGuard tools, nftables/iptables, zenity, notify-send). OpenVPN is
#      not installed: the guided setup is WireGuard-only. For PROVIDER + PROTOCOL=OpenVpn: sudo apt install openvpn;
#   6. the launcher in ~/.local/bin, a "Ghost Browser" menu entry and (if you say yes) a desktop icon, and
#      (if you say yes) hides the stock "Mullvad Browser" menu entry for your user, because that one runs
#      the browser OUTSIDE any VPN with a profile that is kept on disk;
#   7. a guided VPN setup (a VPN vopono supports, or your own WireGuard files), then Ghost Browser's own self-test
#      and exit-IP check. If either fails, the installer says "NOT ready" and exits with an error.
# Files that root installs are copied into a root-owned folder first and checked there, so nothing running
# as you can swap them between the check and the install.
# Nothing else is changed: no sudoers rules, no firewall rules, no browser settings, no services enabled
# by this installer. Your system VPN (if you run one) is not touched. Your Ghost Browser config is never
# overwritten (the guided setup only fills in a VPN when none is set).
set -uo pipefail

# ---- pinned sources (change only together with a re-review) ----
VOPONO_VERSION="1.0.2"
VOPONO_URL="https://github.com/jamesmcm/vopono/releases/download/1.0.2/vopono_1.0.2_amd64.deb"
VOPONO_SHA256="9249ca58db008d5b25fe63fd3190b653cefa486e9c56cf94e5c2b6c9ae017356"
VOPONO_BIN="/usr/bin/vopono"
MULLVAD_KEY_URL="https://repository.mullvad.net/deb/mullvad-keyring.asc"
MULLVAD_KEY_FPR="A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF"   # Mullvad (code signing), as published on mullvad.net
MULLVAD_REPO="https://repository.mullvad.net/deb/stable"
KEYRING="/usr/share/keyrings/mullvad-keyring.asc"
APT_LIST="/etc/apt/sources.list.d/mullvad.list"
APT_SOURCES=(/etc/apt/sources.list /etc/apt/sources.list.d)   # a file (one-line format) or a folder of *.list/*.sources
OS_RELEASE="/etc/os-release"
OWNER_UID=0; OWNER_ROOT=/        # who must own the apt source and key (the tests point these at a temp folder)
STOCK_ENTRY="/usr/share/applications/mullvad-browser.desktop"
PACKAGES=(wireguard-tools nftables iptables zenity libnotify-bin iproute2 procps)
# vopono 1.0.2 providers whose synced WireGuard files work with Ghost Browser. Not offered: ProtonVPN (vopono
# syncs OpenVPN only) and Private Internet Access (its synced WireGuard files are placeholders that only
# vopono's own --provider mode fills in; Ghost Browser always hands vopono a file). Use their WireGuard files.
WG_PROVIDERS=(NordVPN Mullvad IVPN AirVPN AzireVPN MozillaVPN)

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_LAUNCHER="$HERE/ghost-browser.sh"
BIN_DIR="$HOME/.local/bin"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
LAUNCHER="$BIN_DIR/ghost-browser.sh"
MENU_ENTRY="$APP_DIR/ghost-browser.desktop"
STOCK_OVERRIDE="$APP_DIR/mullvad-browser.desktop"
CONFIG_FILE="${GHOST_BROWSER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ghost-browser/config}"   # as the launcher

DRY=0; ASSUME_YES=0; SETUP=1; FAILED=0; HAVE_SOURCE=0
SECURE_DIR=""; USER_TMP=""

say()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY )); then say "would run: $*"; else "$@"; fi; }      # for steps that change something
stamp() { date +%Y%m%d-%H%M%S; }

# ask "question" default(y|n) -> 0 for yes. Never reads a password. --yes and --dry-run take the default.
ask() {
    local q="$1" def="$2" a
    if (( ASSUME_YES || DRY )); then [[ $def == y ]]; return; fi
    while :; do
        read -r -p "[install] $q [$([[ $def == y ]] && echo Y/n || echo y/N)] " a || return 1
        a="${a,,}"; a="${a:-$def}"
        case "$a" in y|yes) return 0 ;; n|no) return 1 ;; esac
    done
}

cleanup() {
    local h
    if [[ -n $SECURE_DIR && $SECURE_DIR == /tmp/ghost-browser-install.* ]]; then
        sudo -n rm -rf -- "$SECURE_DIR" 2>/dev/null || warn "left a root-owned temp folder: sudo rm -rf $SECURE_DIR"
    fi
    if [[ -n $USER_TMP && -d $USER_TMP ]]; then
        for h in "$USER_TMP"/gpg.*; do [[ -d $h ]] && gpgconf --homedir "$h" --kill all >/dev/null 2>&1; done
        rm -rf -- "$USER_TMP"
    fi
}

# Downloads over HTTPS only (no redirect to plain HTTP), TLS 1.2 or newer.
fetch() { curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 2 -o "$2" -- "$1"; }

# A root-owned folder for files that root will act on, so nothing running as you can swap a file
# between the check and its use.
secure_dir() {
    [[ -n $SECURE_DIR ]] && return 0
    SECURE_DIR="$(sudo mktemp -d /tmp/ghost-browser-install.XXXXXXXX)" || die "could not create a root-owned temp folder"
    sudo chmod 755 -- "$SECURE_DIR" || die "could not set up $SECURE_DIR"
}
# Removed as soon as root is done with it (sudo's login is still fresh then); the exit trap is the fallback.
drop_secure_dir() {
    [[ -n $SECURE_DIR ]] || return 0
    sudo rm -rf -- "$SECURE_DIR" && SECURE_DIR="" || warn "could not remove $SECURE_DIR (remove it by hand: sudo rm -rf $SECURE_DIR)"
}
# root_copy SRC NAME -> prints the root-owned copy's path. Your shell opens SRC and only its bytes reach
# root, so a link planted at SRC cannot make root read a file you could not read yourself.
root_copy() {
    [[ -f $1 && ! -L $1 ]] || return 1
    sudo install -m 644 -o root -g root -- /dev/stdin "$SECURE_DIR/$2" < "$1" && printf '%s\n' "$SECURE_DIR/$2"
}
# root_write TEXT DEST: writes TEXT as a root-owned 644 file, then checks what landed.
root_write() {
    printf '%s\n' "$1" | sudo install -m 644 -o root -g root -- /dev/stdin "$2" || return 1
    [[ $(cat -- "$2") == "$1" ]]
}

# gpg in a throwaway home; the agent it may start is stopped again.
gpg_tmp() { local h; h="$(mktemp -d "$USER_TMP/gpg.XXXXXX")" || return 1; chmod 700 -- "$h"; printf '%s\n' "$h"; }
gpg_done() { gpgconf --homedir "$1" --kill all >/dev/null 2>&1; rm -rf -- "$1"; }

# key_import FILE HOME: imports FILE (public parts only) and prints a problem, or nothing if it held
# exactly one key, Mullvad's, and no secret key.
key_import() {
    local f="$1" h="$2" pubs secs
    gpg --homedir "$h" --batch --quiet --import --import-options import-minimal -- "$f" >/dev/null 2>&1 \
        || { echo "gpg could not read it as a key"; return; }
    pubs="$(gpg --homedir "$h" --batch --with-colons --list-keys 2>/dev/null \
            | awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; want = 0}')"
    secs="$(gpg --homedir "$h" --batch --with-colons --list-secret-keys 2>/dev/null | grep -c '^sec')"
    [[ $pubs == "$MULLVAD_KEY_FPR" && $secs == 0 ]] \
        || echo "it is not exactly Mullvad's key $MULLVAD_KEY_FPR (keys found: $(echo $pubs); secret keys: $secs)"
}
# key_problem FILE: for a key file apt will use. Besides the gpg check, the file must hold exactly one
# armored block, "PGP PUBLIC KEY BLOCK": apt's reader (apt-key) decodes every "-----BEGIN" block whatever
# its header says, while gpg skips non-PGP ones, so a hidden second block would pass gpg and fool apt.
# key_problem FILE: for a key file apt will use. It must be byte-identical to gpg's own clean export of
# Mullvad's key (Mullvad's published file is). Counting armor lines is not enough: apt's reader (apt-key)
# also decodes blocks with other headers and base64 after the checksum line, which gpg skips, so a second
# key can hide where only apt sees it. Byte-identity leaves no room for that, whichever reader apt uses.
key_problem() {
    local f="$1" c p
    [[ -f $f && -r $f && ! -L $f ]] || { echo "it is missing, unreadable or a link"; return; }
    c="$(mktemp "$USER_TMP/canon.XXXXXX")" || { echo "no temp file"; return; }
    if ! p="$(canonical_key "$f" "$c")"; then echo "$p"
    elif ! cmp -s -- "$f" "$c"; then echo "it holds Mullvad's key but is not exactly gpg's clean copy of it (it may hide data apt would read)"
    fi
    rm -f -- "$c"
}
# canonical_key IN OUT: OUT = gpg's own armored export of Mullvad's key from IN (nothing else from IN).
canonical_key() {
    local h p; h="$(gpg_tmp)" || return 1
    p="$(key_import "$1" "$h")"
    if [[ -z $p ]]; then gpg --homedir "$h" --batch --export --armor -- "$MULLVAD_KEY_FPR" > "$2" 2>/dev/null || p="export failed"; fi
    gpg_done "$h"
    [[ -z $p && -s $2 ]] || { echo "${p:-export failed}"; return 1; }
}

sha256_of() { sha256sum -- "$1" | awk '{print $1}'; }

pkg_version() { dpkg-query -W -f='${db:Status-Status} ${Version}' -- "$1" 2>/dev/null | awk '$1 == "installed" {print $2}'; }

# mullvad_entries: every source line apt itself reports whose text mentions Mullvad (any letter case),
# whole lines as "FILE:N ADDRESS". apt lists them, so disabled, commented-out and ignored files never count.
# Fails closed (prints why, returns 1) if apt exits with an error OR prints any warning at all: a warning
# such as "Unable to read ..." or "configured multiple times" means your user's view of the sources can
# differ from the one root's apt will use, and then nothing here could be trusted.
mullvad_entries() {
    local out err rc
    err="$(mktemp "$USER_TMP/apt-err.XXXXXX")" || { echo "no temp file"; return 1; }
    out="$(LC_ALL=C apt-get indextargets --no-release-info --format '$(SOURCESENTRY) $(REPO_URI)' 2> "$err")"; rc=$?
    if (( rc != 0 )) || [[ -s $err ]]; then head -3 -- "$err"; rm -f -- "$err"; return 1; fi
    rm -f -- "$err"
    LC_ALL=C grep -i 'mullvad' <<< "$out" | sort -u
    return 0
}
# root_owned PATH: owned by root and not writable by group or others, and so is every folder above it.
root_owned() {
    local f; f="$(readlink -f -- "$1")" || return 1
    while :; do
        [[ $(stat -c '%u' -- "$f" 2>/dev/null) == "$OWNER_UID" ]] || return 1
        (( (8#$(stat -c '%a' -- "$f") & 8#022) == 0 )) || return 1
        [[ $f == / || $f == "$OWNER_ROOT" ]] && return 0
        f="$(dirname -- "$f")"
    done
}
# check_existing_sources: before apt is first run as root, when Mullvad Browser still has to be installed.
# Review rounds kept finding new ways to write an unsafe source that a parser here read as safe, so nothing
# is parsed any more: a Mullvad source you already have is used only if apt reports exactly one, as line 1
# of THE file this installer writes; that file is byte for byte the text it writes (any release name);
# file and key are root-owned; and the key file is exactly Mullvad's key. Anything else is refused.
check_existing_sources() {
    if [[ -n $(pkg_version mullvad-browser) ]]; then return 0; fi   # nothing will be installed from it: your source is left alone
    local entries=() e out p rel want
    out="$(mullvad_entries)" || die "apt reported a problem reading your package sources, so they cannot be checked: $(tr '\n' ' ' <<< "$out"). Fix that first (sudo apt-get update shows it), then run this again"
    [[ -n $out ]] && mapfile -t entries <<< "$out"
    (( ${#entries[@]} )) || return 0
    local fix="To let this installer set up Mullvad's source itself: rename that file so its name ends in .disabled (apt then ignores it), and run this again"
    for e in "${entries[@]}"; do
        [[ $e == "$APT_LIST:1 https://repository.mullvad.net/deb/stable/" ]] \
            || die "you already have a Mullvad package source this installer did not write ($e). It is not checked here. $fix"
    done
    [[ -f $APT_LIST && ! -L $APT_LIST ]] || die "$APT_LIST is a link or not a plain file. $fix"
    rel="$(LC_ALL=C sed -n '1s/.* \([a-z][a-z]*\) main$/\1/p' -- "$APT_LIST")"
    want="$(mktemp "$USER_TMP/list.XXXXXX")" || die "no temp file"
    printf 'deb [signed-by=%s arch=amd64] %s %s main\n' "$KEYRING" "$MULLVAD_REPO" "$rel" > "$want"
    [[ -n $rel ]] && cmp -s -- "$APT_LIST" "$want" \
        || die "$APT_LIST is not byte for byte the line this installer writes (deb [signed-by=$KEYRING arch=amd64] $MULLVAD_REPO stable main). $fix"
    root_owned "$APT_LIST" || die "$APT_LIST, or a folder above it, is not owned by root or can be changed by others. Fix that, then run this again"
    command -v gpg >/dev/null || die "you have a Mullvad package source and gpg is not installed, so its key cannot be checked. Run: sudo apt install gnupg   then run this again"
    p="$(key_problem "$KEYRING")"
    [[ -z $p ]] || die "your Mullvad source's key file $KEYRING: $p. $fix"
    root_owned "$KEYRING" || die "$KEYRING, or a folder above it, is not owned by root or can be changed by others. Fix that, then run this again"
    HAVE_SOURCE=1
    say "your existing Mullvad package source is exactly the line this installer writes, with exactly Mullvad's key: used as it is"
}




# Exec= value for a .desktop file: quoted per the Desktop Entry spec when the path needs it.
desktop_exec() {
    local p="$1"
    if [[ $p =~ ^[A-Za-z0-9/._+-]+$ ]]; then printf '%s' "$p"; return; fi
    p="${p//\\/\\\\\\\\}"; p="${p//\"/\\\\\"}"; p="${p//\`/\\\\\`}"; p="${p//\$/\\\\\$}"; p="${p//%/%%}"
    printf '"%s"' "$p"
}

menu_entry_text() {
    cat <<EOF
[Desktop Entry]
Type=Application
Name=Ghost Browser
Comment=Disposable browser, VPN-only network namespace, forgets everything on close
Exec=$(desktop_exec "$LAUNCHER")
Icon=web-browser
Terminal=false
StartupNotify=false
Categories=Network;
EOF
}

stock_override_text() {
    cat <<'EOF'
[Desktop Entry]
# Written by the Ghost Browser installer: hides the stock "Mullvad Browser" menu entry for this user.
# That entry runs the browser OUTSIDE any VPN, with a profile that is kept on disk; use "Ghost Browser".
# The system file (/usr/share/applications/mullvad-browser.desktop) is untouched. Undo: delete this file.
Type=Application
Name=Mullvad Browser
Hidden=true
EOF
}

# put_file TEXT DEST MODE: writes only if different; an existing different file is kept as DEST.bak-<time>.
put_file() {
    local text="$1" dest="$2" mode="$3" tmp
    if [[ -f $dest && ! -L $dest ]] && [[ $(cat -- "$dest") == "$text" ]]; then
        say "up to date: $dest"; return 0
    fi
    if (( DRY )); then say "would write: $dest"; return 0; fi
    mkdir -p -- "$(dirname -- "$dest")" || die "could not create $(dirname -- "$dest")"
    if [[ -e $dest || -L $dest ]]; then
        mv -- "$dest" "$dest.bak-$(stamp)" || die "could not keep the old $dest"
        say "kept the old file as $dest.bak-*"
    fi
    tmp="$(mktemp "$dest.XXXXXX")" || die "could not write next to $dest"
    printf '%s\n' "$text" > "$tmp" && chmod "$mode" -- "$tmp" && mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; die "could not write $dest"; }
    say "wrote: $dest"
}

# ---------------- steps ----------------

# Ghost Browser is open if one of its namespaces exists, or the launcher runs as a program (not, say, open in an editor).
check_running() {
    local re; re="$(printf '%s' "$LAUNCHER" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
    if ip netns list 2>/dev/null | grep -q '^vo_gb' \
       || pgrep -u "$(id -u)" -f "^((/usr)?/bin/)?(env )?((/usr)?/bin/)?bash $re( |$)" >/dev/null 2>&1; then
        die "Ghost Browser is running. Close it, then run this again"
    fi
}

check_system() {
    [[ $(id -u) -ne 0 ]] || die "run this as your normal user (it uses sudo itself for the system steps), not as root or with sudo"
    [[ $(uname -s) == Linux ]] || die "Ghost Browser runs on Linux only"
    local id="" like=""
    if [[ -r $OS_RELEASE ]]; then
        id="$(. "$OS_RELEASE" && printf '%s' "${ID:-}")"; like="$(. "$OS_RELEASE" && printf '%s' "${ID_LIKE:-}")"
    fi
    [[ " $id $like " == *" debian "* || " $id $like " == *" ubuntu "* ]] \
        || die "this installer supports Debian, Ubuntu, Linux Mint and their relatives only (this is '${id:-unknown}'). The manual steps are in the README"
    command -v apt-get >/dev/null && command -v dpkg >/dev/null || die "apt-get/dpkg not found"
    [[ $(dpkg --print-architecture) == amd64 ]] || die "Mullvad Browser for Linux is 64-bit Intel/AMD (amd64) only; this is $(dpkg --print-architecture)"
    [[ -f $SRC_LAUNCHER ]] || die "ghost-browser.sh must be next to install.sh ($SRC_LAUNCHER not found)"
    [[ $LAUNCHER != *[[:space:]]* ]] || die "your home folder path has a space in it ($LAUNCHER); Ghost Browser cannot start from such a path"
    if ! (( DRY || ASSUME_YES )) && ! [[ -t 0 ]]; then die "run this in a terminal (it asks questions and your password)"; fi
    check_running   # never replace the launcher while Ghost Browser runs
}

check_sudo() {
    (( DRY )) && return 0
    command -v sudo >/dev/null || die "sudo is not installed. As root: apt install sudo && adduser $(id -un) sudo, then log out and back in, and run this again"
    say "the system steps need your password (sudo)"
    if ! sudo -v; then
        [[ $(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null) == 1 ]] \
            && die "sudo is blocked in this terminal (the 'no new privileges' flag is set, as in some app or IDE terminals). Run the installer from your system's own terminal"
        die "sudo failed. If your user may not use sudo: as root, adduser $(id -un) sudo, then log out and back in"
    fi
}

refresh_and_bootstrap() {
    run sudo apt-get update || warn "apt-get update reported a problem (see above); carrying on"
    local missing=()
    [[ -n $(pkg_version curl) ]] || missing+=(curl)
    [[ -n $(pkg_version ca-certificates) ]] || missing+=(ca-certificates)
    command -v gpg >/dev/null || missing+=(gnupg)
    (( ${#missing[@]} == 0 )) && return 0
    say "first installing: ${missing[*]}"
    run sudo apt-get install -y "${missing[@]}" || die "could not install: ${missing[*]}"
}

install_mullvad_browser() {
    if [[ -n $(pkg_version mullvad-browser) ]]; then
        say "Mullvad Browser $(pkg_version mullvad-browser) is installed (left as it is)"; return 0
    fi
    say "installing Mullvad Browser from Mullvad's apt repository"
    local p
    if (( ! HAVE_SOURCE )); then
        if [[ -e $KEYRING ]] && [[ -z $(key_problem "$KEYRING") ]] && root_owned "$KEYRING"; then
            say "Mullvad's key is already installed and is exactly the published key"
        elif (( DRY )); then
            say "would download $MULLVAD_KEY_URL, check it holds only key $MULLVAD_KEY_FPR, install gpg's clean copy as $KEYRING"
        else
            fetch "$MULLVAD_KEY_URL" "$USER_TMP/key.download" || die "could not download Mullvad's key"
            p="$(canonical_key "$USER_TMP/key.download" "$USER_TMP/key.asc")" \
                || die "the downloaded Mullvad key failed the check: $p. Not installed"
            secure_dir
            local k; k="$(root_copy "$USER_TMP/key.asc" mullvad-keyring.asc)" || die "could not copy the key"
            p="$(key_problem "$k")"; [[ -z $p ]] || die "the copied key failed the check: $p"   # re-checked where root holds it
            if [[ -e $KEYRING || -L $KEYRING ]]; then
                sudo mv -- "$KEYRING" "$KEYRING.$(stamp).bak" || die "could not keep the old $KEYRING"
                warn "$KEYRING was not exactly Mullvad's published key in armored form (or not root-owned); kept it as $KEYRING.*.bak and installed the checked one"
            fi
            sudo install -m 644 -o root -g root -- "$k" "$KEYRING" || die "could not install $KEYRING"
            say "Mullvad's key checked ($MULLVAD_KEY_FPR) and installed"
        fi
        local line="deb [signed-by=$KEYRING arch=amd64] $MULLVAD_REPO stable main"
        if (( DRY )); then say "would write $APT_LIST: $line"
        else
            if [[ -e $APT_LIST ]]; then   # apt uses no Mullvad entry in it (checked): keep it; apt ignores *.bak
                sudo mv -- "$APT_LIST" "$APT_LIST.$(stamp).bak" || die "could not keep the old $APT_LIST"
                say "kept the old $APT_LIST as $APT_LIST.*.bak"
            fi
            root_write "$line" "$APT_LIST" || die "could not write $APT_LIST"
            say "wrote $APT_LIST"
        fi
        # Refresh only Mullvad's list: a broken unrelated source must not stop this step.
        run sudo apt-get update -o Dir::Etc::sourcelist="$APT_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 \
            || die "could not read Mullvad's repository (apt-get update for $APT_LIST failed)"
    fi
    if (( DRY )); then say "would check that mullvad-browser comes from $MULLVAD_REPO, then install it"; return 0; fi
    local ver; ver="$(mullvad_candidate)" || die "$ver"
    run sudo apt-get install -y "mullvad-browser=$ver" || die "could not install mullvad-browser"
}
# mullvad_candidate: the version apt would install, if every source offering it is Mullvad's repository.
# Asked through sudo, so it is root's view of the sources: the same one the install itself uses.
mullvad_candidate() {
    local ver mad n
    ver="$(sudo env LC_ALL=C apt-cache policy mullvad-browser 2>/dev/null | awk '$1 == "Candidate:" {print $2}')"
    [[ -n $ver && $ver != "(none)" ]] || { echo "no mullvad-browser package is available from Mullvad's repository"; return 1; }
    mad="$(sudo env LC_ALL=C apt-cache madison mullvad-browser 2>/dev/null | awk -F'|' -v v="$ver" '
        { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3) } $2 == v { print $3 }')"
    n="$(grep -c . <<< "$mad")"
    [[ $n -ge 1 ]] || { echo "mullvad-browser $ver is not offered by Mullvad's repository"; return 1; }
    # Every source offering that version must be exactly Mullvad's stable repository, amd64.
    if grep -qvE '^https://repository\.mullvad\.net/deb/stable [a-z]+/main amd64 Packages$' <<< "$mad"; then
        echo "mullvad-browser $ver is offered by a source that is not Mullvad's repository ($(grep -vE '^https://repository\.mullvad\.net/deb/stable [a-z]+/main amd64 Packages$' <<< "$mad" | head -1)). Refusing: it must come from Mullvad's repository only"; return 1
    fi
    printf '%s\n' "$ver"
}

install_vopono() {
    local have extra=(); have="$(pkg_version vopono)"
    if [[ $have == "$VOPONO_VERSION" || $have == "$VOPONO_VERSION"-* ]]; then
        say "vopono $have is installed (the tested version)"
    else
        if [[ -n $have ]]; then
            warn "vopono $have is installed. Ghost Browser is tested with $VOPONO_VERSION only: its checks on your WireGuard files copy that version's config reader, and its kill-switch rules were read from that version's code"
            if ! ask "Replace vopono $have with $VOPONO_VERSION?" n; then
                warn "keeping vopono $have. Ghost Browser will run, but on an untested vopono"
                drop_secure_dir; vopono_on_path; return 0
            fi
            extra=(--allow-downgrades)
        fi
        if (( DRY )); then say "would download $VOPONO_URL, check SHA-256 $VOPONO_SHA256, install it without its optional extras"; return 0; fi
        say "downloading vopono $VOPONO_VERSION"
        fetch "$VOPONO_URL" "$USER_TMP/vopono.deb" || die "could not download vopono"
        secure_dir
        local d; d="$(root_copy "$USER_TMP/vopono.deb" "vopono_${VOPONO_VERSION}_amd64.deb")" || die "could not copy vopono"
        [[ $(sha256_of "$d") == "$VOPONO_SHA256" ]] || die "the vopono download does not match the pinned SHA-256 $VOPONO_SHA256. Not installed"
        say "vopono checked (SHA-256 $VOPONO_SHA256)"
        sudo apt-get install -y --no-install-recommends "${extra[@]}" "$d" || die "could not install vopono"
    fi
    drop_secure_dir
    vopono_on_path
}
vopono_on_path() {   # the launcher runs whichever vopono comes first on PATH
    local v; v="$(command -v vopono 2>/dev/null)"
    [[ -z $v || $v == "$VOPONO_BIN" ]] || warn "'vopono' on your PATH is $v, not $VOPONO_BIN: Ghost Browser would run that one. Remove or rename it"
}

install_packages() {
    local missing=() p
    for p in "${PACKAGES[@]}"; do [[ -n $(pkg_version "$p") ]] || missing+=("$p"); done
    if (( ${#missing[@]} == 0 )); then say "the other tools are installed"; return 0; fi
    say "installing: ${missing[*]}"
    run sudo apt-get install -y "${missing[@]}" || die "could not install: ${missing[*]}"
}

install_files() {
    if [[ -f $LAUNCHER && ! -L $LAUNCHER ]] && cmp -s -- "$SRC_LAUNCHER" "$LAUNCHER"; then
        say "up to date: $LAUNCHER"
    elif (( DRY )); then say "would install the launcher: $LAUNCHER"
    else
        mkdir -p -- "$BIN_DIR" || die "could not create $BIN_DIR"
        if [[ -e $LAUNCHER || -L $LAUNCHER ]]; then
            mv -- "$LAUNCHER" "$LAUNCHER.bak-$(stamp)" || die "could not keep the old launcher"
            say "kept the old launcher as $LAUNCHER.bak-*"
        fi
        install -m 755 -- "$SRC_LAUNCHER" "$LAUNCHER" || die "could not install $LAUNCHER"
        say "installed: $LAUNCHER"
    fi
    put_file "$(menu_entry_text)" "$MENU_ENTRY" 644

    local desk; desk="$(desktop_dir)"
    if [[ -d $desk ]]; then
        if [[ -f $desk/ghost-browser.desktop ]] || ask "Put a Ghost Browser icon on your desktop?" y; then
            put_file "$(menu_entry_text)" "$desk/ghost-browser.desktop" 755
            (( DRY )) || gio set -- "$desk/ghost-browser.desktop" metadata::trusted true 2>/dev/null || true
        fi
    fi

    if [[ -f $STOCK_ENTRY || -n $(pkg_version mullvad-browser) || $DRY == 1 ]]; then
        if [[ -f $STOCK_OVERRIDE ]] && grep -q '^Hidden=true' -- "$STOCK_OVERRIDE"; then
            say "the stock \"Mullvad Browser\" menu entry is already hidden for you"
        elif ask "Hide the stock \"Mullvad Browser\" menu entry? (it runs the browser OUTSIDE the VPN and keeps its profile)" y; then
            put_file "$(stock_override_text)" "$STOCK_OVERRIDE" 644
        else
            say "left the stock \"Mullvad Browser\" entry visible. Remember: only \"Ghost Browser\" goes through the VPN"
        fi
    fi
    (( DRY )) || update-desktop-database -- "$APP_DIR" 2>/dev/null || true
}
desktop_dir() { local d; d="$(xdg-user-dir DESKTOP 2>/dev/null)"; [[ -n $d && $d != "$HOME" ]] || d="$HOME/Desktop"; printf '%s' "$d"; }

# set_config KEY VALUE: replaces the first "KEY=" line (set, blank or commented out) in the config.
# Refuses values the launcher would read differently (it cuts at '#', trims spaces, strips wrapping quotes).
set_config() {
    local key="$1" val="$2" tmp
    [[ $val != *$'\n'* && $val != *'#'* && $val != *\\* ]] || die "$key cannot contain a line break, '#' or a backslash"
    [[ $val == "${val#[[:space:]]}" && $val == "${val%[[:space:]]}" ]] || die "$key cannot start or end with a space"
    [[ ! ( ${#val} -ge 2 && ( ( $val == \"* && $val == *\" ) || ( $val == \'* && $val == *\' ) ) ) ]] || die "$key cannot be wrapped in quotes"
    if (( DRY )); then say "would set $key=$val in $CONFIG_FILE"; return 0; fi
    tmp="$(mktemp "$CONFIG_FILE.XXXXXX")" || die "could not write next to $CONFIG_FILE"
    awk -v k="$key" -v v="$val" '
        !done && ($0 ~ "^" k "=" || $0 ~ "^#" k "=") { print k "=" v; done = 1; next }
        { print }
        END { if (!done && v != "") print k "=" v }' "$CONFIG_FILE" > "$tmp" \
        && chmod 600 -- "$tmp" && mv -f -- "$tmp" "$CONFIG_FILE" || { rm -f -- "$tmp"; die "could not update $CONFIG_FILE"; }
}
# A VPN is set when PROVIDER (with SERVERS) or CONFIG_DIR has a value.
# A VPN is set when PROVIDER (with SERVERS) or CONFIG_DIR has a value, read the way the launcher reads it
# (cut at '#', trim spaces, strip one pair of wrapping quotes).
conf_value() {
    [[ -r $CONFIG_FILE ]] || return 0
    awk -v k="$1" '
        { line = $0; sub(/#.*/, "", line); if (line !~ /=/) next
          key = line; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); if (key != k) next
          v = line; sub(/^[^=]*=/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if (length(v) >= 2 && ((v ~ /^".*"$/) || (v ~ /^\047.*\047$/))) v = substr(v, 2, length(v) - 2)
          val = v }
        END { printf "%s", val }' "$CONFIG_FILE"
}
load_ok() {
    [[ -r $CONFIG_FILE ]] || return 1
    [[ -n $(conf_value CONFIG_DIR) ]] && return 0
    [[ -n $(conf_value PROVIDER) && -n $(conf_value SERVERS) ]]
}

setup_vpn() {
    if load_ok; then
        say "your Ghost Browser config already names a VPN ($CONFIG_FILE): left as it is"
        return 0
    fi
    if (( DRY )); then say "would ask which VPN to use and fill it into $CONFIG_FILE"; return 0; fi
    if [[ -e $CONFIG_FILE ]]; then
        say "your Ghost Browser config ($CONFIG_FILE) names no VPN yet"
    else
        "$LAUNCHER" --init >/dev/null || die "could not write the starter config"
    fi
    chmod 600 -- "$CONFIG_FILE" 2>/dev/null
    echo
    say "Which VPN should Ghost Browser use?"
    echo "   1) one vopono can download servers for: ${WG_PROVIDERS[*]}"
    echo "   2) my own WireGuard files (Proton, Private Internet Access, Surfshark, Windscribe, your own server, ...)"
    echo "   3) skip for now (edit $CONFIG_FILE later, or run this installer again)"
    local c; read -r -p "[install] 1, 2 or 3: " c || c=3
    case "$c" in
        1)
            local p="" want i s
            read -r -p "[install] VPN name (as listed above): " want || return 0
            for i in "${WG_PROVIDERS[@]}"; do [[ ${i,,} == "${want,,}" ]] && p="$i"; done
            [[ -n $p ]] || { warn "'$want' is not in the list. Skipped: run the installer again, or set PROVIDER in $CONFIG_FILE"; return 0; }
            say "vopono now downloads $p's WireGuard servers. If it asks for a login or token, type it here in the terminal"
            "$VOPONO_BIN" sync "$p" --protocol Wireguard || { warn "vopono sync failed. Run the installer again, or: vopono sync $p --protocol Wireguard"; return 0; }
            read -r -p "[install] Country code(s) to exit from, e.g. 'us' or 'us ca' (vopono servers $p lists them): " s || s=""
            s="$(printf '%s' "$s" | tr -s ' ' | sed 's/^ //; s/ $//')"
            [[ $s =~ ^[A-Za-z0-9_-]+( [A-Za-z0-9_-]+)*$ ]] || { warn "no valid country code given. Run the installer again, or set PROVIDER and SERVERS in $CONFIG_FILE"; return 0; }
            set_config PROVIDER "$p"
            set_config SERVERS "$s"
            set_config CONFIG_DIR ""
            ;;
        2)
            local d; read -r -p "[install] Folder holding your WireGuard .conf files: " d || return 0
            [[ $d == "~/"* ]] && d="$HOME/${d:2}"
            [[ -d $d ]] || { warn "'$d' is not a folder. Run the installer again, or set CONFIG_DIR in $CONFIG_FILE"; return 0; }
            d="$(cd -- "$d" && pwd -P)"
            chmod 700 -- "$d" 2>/dev/null && say "made $d private (only you can open it: the files hold your VPN key)"
            set_config CONFIG_DIR "$d"
            set_config PROVIDER ""
            ;;
        *) say "skipped. Edit $CONFIG_FILE or run this installer again, then: $LAUNCHER --dry-run"; return 0 ;;
    esac
    say "checking the config (no VPN yet):"
    "$LAUNCHER" --dry-run || { FAILED=1; warn "the config check failed (see above). Fix $CONFIG_FILE, then run: $LAUNCHER --dry-run"; }
    return 0
}

final_checks() {
    (( DRY )) && { say "would offer the self-test and the exit-IP check"; return 0; }
    if ask "Run Ghost Browser's self-test now? (builds a test namespace with a dead tunnel; no VPN account needed)" y; then
        "$LAUNCHER" --selftest || { FAILED=1; warn "the self-test did not pass. Do not use Ghost Browser until it does"; }
    fi
    if load_ok && ask "Run the exit-IP check now? (connects to your VPN in a namespace, no browser)" y; then
        "$LAUNCHER" --check || { FAILED=1; warn "the exit-IP check did not pass"; }
    fi
}

uninstall() {
    local desk f; desk="$(desktop_dir)"
    remove_if() {   # remove_if FILE EXPECTED-TEXT: only a file the installer wrote, unchanged
        [[ -f $1 && ! -L $1 ]] || return 0
        if [[ $(cat -- "$1") == "$2" ]]; then run rm -f -- "$1"; (( DRY )) || say "removed: $1"
        else say "left alone (changed since install): $1"; fi
    }
    if [[ -f $LAUNCHER && ! -L $LAUNCHER ]]; then
        if cmp -s -- "$SRC_LAUNCHER" "$LAUNCHER"; then run rm -f -- "$LAUNCHER"; (( DRY )) || say "removed: $LAUNCHER"
        else say "left alone (not this version's launcher): $LAUNCHER"; fi
    fi
    remove_if "$MENU_ENTRY" "$(menu_entry_text)"
    remove_if "$desk/ghost-browser.desktop" "$(menu_entry_text)"
    remove_if "$STOCK_OVERRIDE" "$(stock_override_text)"
    for f in "$LAUNCHER".bak-* "$MENU_ENTRY".bak-* "$STOCK_OVERRIDE".bak-*; do [[ -e $f ]] && say "backup kept: $f"; done
    (( DRY )) || update-desktop-database -- "$APP_DIR" 2>/dev/null || true
    say "kept (remove by hand if you want): your config ($(dirname -- "$CONFIG_FILE")), vopono's server lists (~/.config/vopono),"
    say "  and the packages: sudo apt remove vopono mullvad-browser; Mullvad's apt source $APT_LIST and key $KEYRING"
}

main() {
    local mode=install a
    for a in "$@"; do
        case "$a" in
            --dry-run)   DRY=1 ;;
            --yes|-y)    ASSUME_YES=1 ;;
            --no-setup)  SETUP=0 ;;
            --uninstall) mode=uninstall ;;
            --help|-h)   sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
            *) die "unknown option '$a' (see --help)" ;;
        esac
    done
    (( DRY )) && say "dry run: nothing will be changed"
    USER_TMP="$(mktemp -d)" || die "could not create a temp folder"
    trap cleanup EXIT
    trap 'exit 130' INT TERM HUP
    if [[ $mode == uninstall ]]; then
        [[ $(id -u) -ne 0 ]] || die "run this as your normal user, not root"
        check_running
        uninstall; exit 0
    fi
    check_system
    check_existing_sources   # before apt runs as root at all
    check_sudo
    refresh_and_bootstrap
    install_mullvad_browser
    install_vopono
    install_packages
    install_files
    if (( SETUP )) && ! (( ASSUME_YES )); then setup_vpn; fi
    (( ASSUME_YES )) || final_checks
    finish
}
finish() {
    if (( FAILED )); then
        say "NOT ready: a check above failed. Fix it, then run: $LAUNCHER --selftest"
        exit 1
    fi
    if (( SETUP && ! ASSUME_YES && ! DRY )) && ! load_ok; then
        say "installed, but NOT ready: no VPN is set. Run this installer again, or edit $CONFIG_FILE"
        exit 1
    fi
    say "done. Open \"Ghost Browser\" from your menu$( [[ -d $(desktop_dir) ]] && echo ' or desktop'). Help: $LAUNCHER --help"
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
