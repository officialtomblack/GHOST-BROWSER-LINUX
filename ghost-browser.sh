#!/usr/bin/env bash
# ghost-browser.sh - "Ghost Browser": a disposable Mullvad Browser inside a vopono VPN namespace.
#
#  - Network: vopono builds a fresh network namespace whose only way out is the VPN tunnel.
#    The namespace IS the kill switch: if the tunnel drops, the browser has no other route.
#  - Amnesic: every run gets a brand-new profile in RAM ($XDG_RUNTIME_DIR, tmpfs), deleted
#    when the browser closes. Nothing from one run is visible to the next.
#  - Stock browser: no prefs, theme, fonts or window size are touched. Only HOME and TMPDIR are
#    pointed at the throwaway folder; Mullvad Browser's own start script does the rest.
#  - Checked, not trusted: before the browser starts, the launcher itself confirms it is in a separate
#    namespace whose internet route goes through the tunnel (for WireGuard: a full /0 tunnel).
#
# Docs: README.md (how it works, what it protects against, and what it does not).
#
# Settings live in a config file, not in this script (see --init):
#   ${XDG_CONFIG_HOME:-~/.config}/ghost-browser/config     (override the path with GHOST_BROWSER_CONFIG)
#
# Usage:
#   ghost-browser.sh                    launch Ghost Browser (a server that does not answer is swapped for another, up to 3 tries)
#   ghost-browser.sh --init             write a starter config file (never overwrites one) and list synced providers
#   ghost-browser.sh --dry-run          pick a server and show what would run; builds nothing, needs no sudo
#   ghost-browser.sh --check            no browser: show the exit IP seen from inside the namespace
#   ghost-browser.sh --selftest         no VPN account needed: namespace plumbing + dead-tunnel leak test
#   ghost-browser.sh --selftest-browser open Ghost Browser inside a dead tunnel (every page must fail)
#   ghost-browser.sh --selftest-retry   attempt 1 on a dead tunnel: it must be caught and replaced by a working server
#   ghost-browser.sh --help             this text
#
# What is checked, and what is not:
#   - Every launch, inside the namespace, before the browser starts: it is a separate network namespace,
#     and the internet route goes through the VPN tunnel (WireGuard: a full 0.0.0.0/0 tunnel, which is
#     when vopono turns its kill switch on). Otherwise Ghost Browser is not opened.
#   - CONFIG_DIR (your own files) takes WireGuard .conf files only, each checked before vopono (as root)
#     gets it: exactly one [Interface] and one [Peer], AllowedIPs with 0.0.0.0/0, plain ASCII lines in
#     the form vopono reads, owned by you and writable only by you. OpenVPN files are not accepted
#     there: openvpn runs as root and vopono does not limit what a file can make it run.
#   - PROVIDER files are written by vopono itself and are not opened by this script; only the route
#     check above applies to them.
#   - Not a sandbox: the browser runs as you, on your desktop, and can read your files. Swap (RAM
#     written to disk) can hold traces unless it is encrypted.

set -uo pipefail

# Defaults. Every one can be overridden in the config file; none is a provider or country.
PROVIDER=""          # vopono provider name, as `vopono providers` lists it (e.g. NordVPN, Mullvad, IVPN)
SERVERS=""           # one or more country codes / server-name prefixes, space-separated, as
                     #   `vopono servers <provider> --prefix <p>` matches them. Each run picks one
                     #   prefix at random, then one synced server at random among its matches.
CONFIG_DIR=""        # instead of PROVIDER: a folder of your own WireGuard .conf files (any VPN, or your own server).
                     #   SERVERS then optionally filters by file-name prefix; blank = every file.
AUTH_FILE=""         # OpenVPN (PROVIDER mode) only, optional: file with username on line 1, password on line 2
PROTOCOL="Wireguard" # Wireguard or OpenVpn (PROVIDER mode: must match what `vopono sync` downloaded; CONFIG_DIR: Wireguard only)
HOST_IFACE=""        # optional - host interface vopono NATs out of. Blank = auto: the interface the
                     #   kernel really routes internet traffic out of (nordlynx while NordVPN is up).
BROWSER=/usr/bin/mullvad-browser   # a Firefox-family browser (needs --new-instance). Only Mullvad Browser is tested.
CONFIG_FILE="${GHOST_BROWSER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ghost-browser/config}"

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
LEAK_URL=https://am.i.mullvad.net/json   # works for any VPN: reports the IP the internet sees
TITLE="Ghost Browser"
RUN_BASE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

have_tty() { [[ -t 0 && -t 1 ]]; }
say() { printf '[ghost-browser] %s\n' "$*"; }
fail() {
    say "ERROR: $*" >&2
    have_tty || zenity --error --no-markup --title="$TITLE" --width=480 --text="$*" 2>/dev/null
    exit 1
}

# ---------- entry points vopono runs INSIDE the namespace, as your user ----------

# A WireGuard tunnel to a dead server still comes "up": there is no handshake step that can fail, so
# vopono reports success and only the pages fail. So before the browser opens, one DNS lookup goes
# through the tunnel to the namespace's resolver (the VPN provider's own DNS - no website is contacted).
# No answer = dead server. The lookup is plain glibc (no nscd on the host to short-circuit it).
PROBE_NAME=example.com
PROBE_SECONDS=10
tunnel_answers() { timeout "$PROBE_SECONDS" getent ahostsv4 "$PROBE_NAME" >/dev/null 2>&1; }

# The launcher's own check, made here instead of trusting vopono: the route to the internet must leave
# through a point-to-point tunnel device (WireGuard or OpenVPN), never through the veth cable to the host.
# For WireGuard, vopono adds its kill switch only together with a whole-internet (/0) route through the
# tunnel (vopono 1.0.2 wireguard.rs has_default_allowed_ip). A split-tunnel config, including the
# 0.0.0.0/1 + 128.0.0.0/1 pair that still carries this test address, gets routes but NO kill switch,
# and vopono only logs a warning. So for WireGuard the /0 route itself must be there.
# OpenVPN: vopono adds its kill switch whatever the routes are.
route_is_tunnel() {
    local dev
    dev="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
    [[ -n $dev ]] && ip -o link show dev "$dev" 2>/dev/null | grep -q '<[^>]*POINTOPOINT' || return 1
    if ip -d -o link show dev "$dev" 2>/dev/null | grep -qw wireguard; then
        [[ -n $(ip -4 route show table all default dev "$dev" 2>/dev/null) ]] || return 1
    fi
    return 0
}

net_ns_id() { readlink /proc/self/ns/net 2>/dev/null | tr -dc '0-9'; }

# $1 = run folder, $2 = browser path, $3 = the host's network namespace id, $4 = --no-probe (optional).
# Starts the stock browser with HOME and TMPDIR moved into the RAM folder.
inner() {
    local run="$1" browser="$2" host_ns="$3" ns
    [[ $run == "$RUN_BASE"/ghost-browser.* && -d $run ]] || fail "refusing odd run folder: $run"
    [[ -x $browser ]] || fail "browser not found: $browser"
    # Never a browser on the host's own network, however this was called. Fails closed: an id that
    # cannot be read counts as "same".
    ns="$(net_ns_id)"
    [[ $host_ns =~ ^[0-9]+$ && $ns =~ ^[0-9]+$ && $ns != "$host_ns" ]] \
        || fail "refusing to start the browser: this is not a separate VPN namespace"
    if ! route_is_tunnel; then
        say "SECURITY: the route to the internet is not a full tunnel through the VPN; the browser was not started" >&2
        : > "$run/not-tunnel"    # the outer launcher sees this file and stops (no retry)
        exit 76
    fi
    if [[ ${4:-} != --no-probe ]] && ! tunnel_answers; then
        : > "$run/tunnel-dead"   # the outer launcher sees this file and tries another server
        exit 75
    fi
    export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"   # pin it before HOME moves
    export HOME="$run/home"
    # The browser starts downloads (and keeps files opened from a download) in its temp folder.
    # Unset, that is /tmp, which is often on disk; keep it in RAM with everything else.
    export TMPDIR="$run/tmp"
    mkdir -p -- "$HOME" "$TMPDIR"
    exec "$browser" --new-instance
}

# Reads KEY=VALUE lines from the config file. It is parsed, never sourced, so the file cannot run code,
# and an unknown key is an error (a typo would otherwise silently fall back to a default).
load_config() {
    [[ -e $CONFIG_FILE ]] || return 0
    [[ -r $CONFIG_FILE ]] || fail "cannot read the config file: $CONFIG_FILE"
    local line key val n=0
    # The file is read on fd 3, not stdin: fail() decides between a terminal message and a popup by
    # testing whether stdin is a terminal, so stdin must stay untouched inside this loop.
    while IFS= read -r line <&3 || [[ -n $line ]]; do
        n=$((n + 1))
        line="${line%%#*}"                                   # drop comments
        line="${line#"${line%%[![:space:]]*}"}"              # trim leading space
        line="${line%"${line##*[![:space:]]}"}"              # trim trailing space
        [[ -n $line ]] || continue
        [[ $line == *=* ]] || fail "$CONFIG_FILE line $n: expected KEY=VALUE, got '$line'"
        key="${line%%=*}"; val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        if [[ $val == \"*\" || $val == \'*\' ]]; then val="${val:1:${#val}-2}"; fi
        case "$key" in
            PROVIDER|SERVERS|HOST_IFACE|BROWSER) printf -v "$key" '%s' "$val" ;;
            CONFIG_DIR|AUTH_FILE) [[ $val == "~/"* ]] && val="$HOME/${val:2}"   # parsed, not sourced: expand ~ here
                                  printf -v "$key" '%s' "$val" ;;
            PROTOCOL)
                case "${val,,}" in
                    wireguard) PROTOCOL=Wireguard ;;
                    openvpn)   PROTOCOL=OpenVpn ;;
                    *) fail "$CONFIG_FILE line $n: PROTOCOL must be Wireguard or OpenVpn, got '$val'" ;;
                esac ;;
            *) fail "$CONFIG_FILE line $n: unknown setting '$key' (allowed: PROVIDER CONFIG_DIR SERVERS PROTOCOL AUTH_FILE HOST_IFACE BROWSER)" ;;
        esac
    done 3< "$CONFIG_FILE"
    [[ $BROWSER != *[[:space:]]* ]] || fail "BROWSER must be a path without spaces, got '$BROWSER'"
    [[ -z $PROVIDER || -z $CONFIG_DIR ]] || fail "set PROVIDER or CONFIG_DIR in $CONFIG_FILE, not both"
    [[ -z $CONFIG_DIR || $PROTOCOL == Wireguard ]] \
        || fail "CONFIG_DIR takes WireGuard files only: openvpn runs as root, and a downloaded OpenVPN file can make it run programs (vopono does not stop that). Use your VPN's WireGuard files, or PROVIDER with 'vopono sync <provider> --protocol OpenVpn'"
    if [[ -n $AUTH_FILE ]]; then
        [[ $PROTOCOL == OpenVpn ]] || fail "AUTH_FILE is for OpenVpn only (PROTOCOL is $PROTOCOL). CONFIG_DIR takes WireGuard files, which need no login file"
        [[ -r $AUTH_FILE ]] || fail "cannot read AUTH_FILE: $AUTH_FILE"
    fi
}

# ---------- checks on a WireGuard file from CONFIG_DIR, before vopono (as root) is given it ----------
# They print the first reason the file is unsafe, or nothing, and never print the file (it holds the VPN
# key). PROVIDER mode never calls them: vopono writes those files itself from the provider's data, and
# the owner's rule is that the launcher never opens them; there, only route_is_tunnel() in inner() runs.
# CONFIG_DIR takes no OpenVPN files: openvpn runs as root, vopono 1.0.2 caps --script-security only in
# its daemon mode, and openvpn's own file syntax has too many quirks to check from outside (three ways
# around an allowlist were found in review: a close tag with text after it, 256-byte line chunks,
# "setenv opt <option>").

# The file must be in exactly the form vopono 1.0.2 reads (wireguard_config.rs), so that what is checked
# here is what vopono sees: plain ASCII; every line empty, a '#' comment with text after the '#',
# "[Interface]" or "[Peer]" (optionally followed by spaces and such a comment), or "Key = value" with the key at the start of the line;
# exactly one of each section. A value ends at '#'. vopono adds its kill switch only for a /0 entry
# (has_default_allowed_ip) and Ghost Browser needs a full IPv4 tunnel, so [Peer] AllowedIPs must hold an
# exact 0.0.0.0/0 entry. Lines vopono could not parse are refused here too, so vopono never prints a
# parse error that quotes the file.
wg_problem() {   # $1 = file
    LC_ALL=C awk '
        function bad(m) { print m; done = 1; exit }
        { sub(/\r$/, "") }
        /[^\t -~]/                                  { bad("line " NR " has a non-ASCII or control character") }
        /^$/ || /^#./                               { next }   # vopono: a comment needs a character after the #
        /^\[/ {
            if      ($0 ~ /^\[Interface\][ \t]*(#.+)?$/) { sec = "i"; ifc++ }
            else if ($0 ~ /^\[Peer\][ \t]*(#.+)?$/)      { sec = "p"; peers++ }
            else bad("line " NR " is a section other than [Interface] or [Peer]")
            next
        }
        !/^[A-Za-z0-9]+[ \t]*=/                     { bad("line " NR " is not a \"Key = value\" line in the form vopono reads") }
        sec == ""                                   { bad("line " NR " comes before the first section") }
        sec == "p" && /^AllowedIPs[ \t]*=/ {
            v = $0; sub(/^[^=]*=/, "", v); sub(/#.*/, "", v)
            n = split(v, a, ",")
            for (i = 1; i <= n; i++) { x = a[i]; gsub(/^[ \t]+|[ \t]+$/, "", x); if (x == "0.0.0.0/0") full = 1 }
        }
        END {
            if (done) exit
            if (ifc != 1 || peers != 1) print "it needs exactly one [Interface] and one [Peer] section (it has " ifc + 0 " and " peers + 0 ")"
            else if (!full) print "its [Peer] AllowedIPs has no 0.0.0.0/0 (a full IPv4 tunnel), which Ghost Browser requires: without a /0 route vopono adds no kill switch"
        }' "$1"
}

vpn_file_problem() {   # $1 = WireGuard file from CONFIG_DIR
    local f="$1" me mode_f mode_d
    [[ -r $f ]] || { echo "it cannot be read"; return; }
    # Whoever can change the file, or swap it in the folder, between this check and vopono reading it
    # as root defeats the check; so both must be yours and writable only by you.
    me="$(id -u)"
    [[ $(stat -L -c %u -- "$f") == "$me" && $(stat -L -c %u -- "$CONFIG_DIR") == "$me" ]] \
        || { echo "it, or the folder $CONFIG_DIR, is not owned by you"; return; }
    mode_f="$(stat -L -c %a -- "$f")"; mode_d="$(stat -L -c %a -- "$CONFIG_DIR")"
    (( (8#$mode_f & 8#022) == 0 && (8#$mode_d & 8#022) == 0 )) \
        || { echo "it, or the folder $CONFIG_DIR, can be changed by other users (fix: chmod go-w)"; return; }
    # A NUL byte makes text tools skip lines that vopono would still read.
    [[ $(LC_ALL=C tr -d '\000' < "$f" | wc -c) -eq $(wc -c < "$f") ]] || { echo "it contains NUL bytes"; return; }
    wg_problem "$f"
}

# Warn (never print contents) when a file holding a key or password is readable by other users.
check_private() {   # $1 = file, $2 = what it holds
    local mode; mode="$(stat -L -c %a -- "$1" 2>/dev/null)" || return 0
    [[ ${mode: -2} == 00 ]] || say "WARNING: $1 holds $2 and other users can read it (mode $mode). Fix: chmod 600 '$1'"
}

write_starter_config() {   # --init: never overwrites. Leaves PROVIDER and SERVERS blank on purpose.
    if [[ -e $CONFIG_FILE ]]; then
        say "config already exists, left alone: $CONFIG_FILE"
    else
        mkdir -p -- "$(dirname -- "$CONFIG_FILE")" || fail "could not create $(dirname -- "$CONFIG_FILE")"
        cat > "$CONFIG_FILE" <<'EOF'
# ghost-browser config. One KEY=VALUE per line, '#' starts a comment.

# Set ONE of PROVIDER or CONFIG_DIR.
#
# A) VPN provider vopono knows, spelled as `vopono providers` lists it (NordVPN, Mullvad, IVPN, ...).
#    Run `vopono sync <provider>` first.
PROVIDER=
#
# B) Any other VPN with WireGuard files (Proton, Surfshark, Windscribe, your own server, ...): download
#    its WireGuard .conf files into one folder and name it here. Keep that folder private (chmod 700):
#    the files hold your VPN key. Each file must be a full tunnel (AllowedIPs = 0.0.0.0/0). OpenVPN
#    files are not accepted here (they could make openvpn run programs as root); use PROVIDER for OpenVPN.
#CONFIG_DIR=~/vpn-configs

# Where to exit: one or more prefixes, separated by spaces. Each launch picks one prefix at random,
# then one matching server at random. Example: SERVERS=us ca
#   with PROVIDER:   country codes / server names; REQUIRED. `vopono servers <provider>` lists them.
#   with CONFIG_DIR: start of the file names; optional (blank = any file in the folder).
SERVERS=

# Wireguard or OpenVpn (OpenVpn with PROVIDER only). Must match what you synced.
PROTOCOL=Wireguard

# OpenVpn (PROVIDER mode) only, if your VPN asks for a login: username on line 1, password on line 2.
#AUTH_FILE=~/vpn-configs/login.txt

# Host network interface to NAT out of. Leave blank: it is detected on each launch.
#HOST_IFACE=

# Browser to run. Must be Firefox-family (it is started with --new-instance). Only Mullvad Browser is tested.
#BROWSER=/usr/bin/mullvad-browser
EOF
        say "wrote a starter config: $CONFIG_FILE"
    fi
    say "now set PROVIDER and SERVERS in it (or CONFIG_DIR, for a VPN vopono does not list)."
    local synced=""
    command -v vopono >/dev/null && synced="$(vopono providers 2>/dev/null | awk -F'\t' '$4 == "true" {print "  " $2 " (" $NF " servers)"}')"
    if [[ -n $synced ]]; then say "synced with vopono:"; printf '%s\n' "$synced"
    else say "no provider is synced yet. Run: vopono sync <provider>   (list them with: vopono providers)"; fi
}

probe() {   # $1 = plumbing | dead | exit. Prints what the namespace looks like, then tests it.
    say "netns $(readlink /proc/self/ns/net) | resolv.conf: $(grep -h '^nameserver' /etc/resolv.conf | tr '\n' ' ')"
    ip -br addr
    ip route
    case "$1" in
        plumbing)
            if curl -sS -m 15 "$LEAK_URL"; then echo; say "PASS plumbing: namespace reaches the internet through the host"
            else say "FAIL plumbing: namespace cannot reach the internet"; fi ;;
        dead)
            if curl -sS -m 8 -o /dev/null https://1.1.1.1 2>/dev/null; then say "FAIL dead-tunnel: reached 1.1.1.1 with the tunnel down - LEAK"
            elif curl -sS -m 8 -o /dev/null "$LEAK_URL" 2>/dev/null; then say "FAIL dead-tunnel: reached $LEAK_URL with the tunnel down - LEAK"
            else say "PASS dead-tunnel: nothing gets out with the tunnel down"; fi ;;
        exit)
            curl -sS -m 20 "$LEAK_URL" || say "FAIL exit: no answer through the tunnel"; echo ;;
    esac
}

case "${1:-}" in
    --inner) inner "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    --probe) probe "${2:-}"; exit 0 ;;
esac

# ---------- outer launcher: runs on the host as your user ----------

[[ $(id -u) -ne 0 ]] || fail "run this as your normal user, not root"
case "${1:-}" in
    --help|-h) sed -n '/^# Settings live/,/can hold traces unless it is encrypted/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --init)    write_starter_config; exit 0 ;;
esac
load_config
command -v vopono >/dev/null || fail "vopono not found (https://github.com/jamesmcm/vopono)"
[[ -x $BROWSER ]] || fail "browser not found at $BROWSER (set BROWSER in $CONFIG_FILE)"
[[ $(findmnt -n -o FSTYPE -T "$RUN_BASE" 2>/dev/null) == tmpfs ]] \
    || fail "$RUN_BASE is not RAM (tmpfs) - refusing to put a browser profile on disk"

RUN="$(mktemp -d "$RUN_BASE/ghost-browser.XXXXXXXX")" || fail "could not create a run folder in $RUN_BASE"
cleanup() { [[ -n ${RUN:-} && $RUN == "$RUN_BASE"/ghost-browser.* ]] && rm -rf -- "$RUN"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
# From the menu our stdout would land in ~/.xsession-errors (on disk): keep it in the RAM folder instead.
# Only for the modes that open a browser; --dry-run, --check and --selftest keep printing when piped.
case "${1:-}" in ""|--selftest-retry|--selftest-browser) have_tty || exec >> "$RUN/ghost-browser.log" 2>&1 ;; esac

# From the menu there is no terminal for sudo, so ask for the password in a zenity box.
askpass=()
if ! have_tty; then
    printf '#!/bin/sh\nexec zenity --password --title="%s - password to build the VPN namespace"\n' "$TITLE" > "$RUN/askpass"
    chmod 700 "$RUN/askpass"
    export SUDO_ASKPASS="$RUN/askpass"
    askpass=(-A)
fi

iface="${HOST_IFACE:-$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')}"
[[ -n $iface ]] || fail "the host has no route to the internet"
HOST_NS="$(net_ns_id)"   # inner() refuses to start the browser in this namespace
[[ -n $HOST_NS ]] || fail "cannot read this process's network namespace (/proc/self/ns/net)"

target=()
tried=()       # servers already tried this launch; need_vpn never picks one twice
refused=()     # CONFIG_DIR files refused as unsafe this launch (names), and why (for the final error)
refused_why=()
MAX_TRIES=3
VIA="${PROVIDER:-own configs in $CONFIG_DIR}"   # for messages only

# Every candidate as "name<TAB>config path". Provider mode asks vopono; CONFIG_DIR mode lists the folder.
list_servers() {   # $1 = prefix ("" = all; CONFIG_DIR mode only)
    if [[ -n $PROVIDER ]]; then
        # Pick the exact server here, not inside vopono: its --server is a prefix match, so "us1"
        # would also match us10...us199. The chosen config file is handed over as --custom.
        vopono servers "$PROVIDER" --protocol "$PROTOCOL" --prefix "$1" 2>/dev/null |
            awk -F'\t' '$1 != "id" && NF >= 6 {print $1 "\t" $NF}'
        return
    fi
    local f
    for f in "$CONFIG_DIR/$1"*.conf; do   # $1 is quoted: a prefix is matched literally, never as a pattern
        [[ -f $f ]] && printf '%s\t%s\n' "$(basename -- "${f%.*}")" "$f"
    done
}

need_vpn() {
    if [[ -n $CONFIG_DIR ]]; then
        [[ -d $CONFIG_DIR ]] || fail "CONFIG_DIR is not a folder: $CONFIG_DIR"
    else
        [[ -n $PROVIDER && -n $SERVERS ]] \
            || fail "set PROVIDER and SERVERS (or CONFIG_DIR). Run '$(basename "$SELF") --init', then fill them in: $CONFIG_FILE"
    fi
    local prefixes=("") order prefix rows r t i name why seen=0 empty=() found=() found_rows=() pick="" conf
    [[ -n $SERVERS ]] && read -r -a prefixes <<< "$SERVERS"
    # Every prefix is listed first, so one that matches nothing (likely a typo) is always named in a
    # warning and skipped; it never fails a launch. Then prefixes in random order; in each, candidates
    # in random order; the first untried one wins (in CONFIG_DIR mode, the first untried one that passes
    # vpn_file_problem). A refused file is named in a warning, remembered in refused[], and never
    # offered again this launch.
    mapfile -t order < <(shuf -e -- "${prefixes[@]}")
    for prefix in "${order[@]}"; do
        r="$(list_servers "$prefix")"
        if [[ -z $r ]]; then empty+=("'$prefix'"); else found+=("$prefix"); found_rows+=("$r"); fi
    done
    for i in "${!found[@]}"; do
        mapfile -t rows <<< "${found_rows[$i]}"
        seen=$((seen + ${#rows[@]}))
        while IFS= read -r r; do
            name="${r%%$'\t'*}"
            for t in "${tried[@]}" "${refused[@]}"; do [[ $name == "$t" ]] && continue 2; done
            if [[ -n $CONFIG_DIR ]]; then
                why="$(vpn_file_problem "${r#*$'\t'}")"
                if [[ -n $why ]]; then
                    say "WARNING: skipping $name: $why"
                    refused+=("$name"); refused_why+=("$name: $why")
                    continue
                fi
            fi
            pick="$r"; break 2
        done < <(printf '%s\n' "${rows[@]}" | shuf)
    done
    [[ ${#empty[@]} -eq 0 || ${#empty[@]} -eq ${#order[@]} ]] || say "WARNING: nothing matches SERVERS prefix ${empty[*]} - check SERVERS in $CONFIG_FILE"
    if [[ -z $pick ]]; then
        # The reasons go into the error itself: from the menu, the warnings above are only in a log
        # that is deleted on exit, and the popup is all the user sees. At most 5, so it stays readable.
        local why_all="" n=${#refused_why[@]}
        if (( n > 0 )); then
            why_all=" Refused as unsafe ($n): $(printf '%s; ' "${refused_why[@]:0:5}")"
            (( n > 5 )) && why_all+="and $((n - 5)) more."
        fi
        if [[ $seen -eq 0 && -n $PROVIDER ]]; then
            fail "no synced $PROVIDER $PROTOCOL servers match SERVERS ($SERVERS). Check 'vopono servers $PROVIDER', fix SERVERS, or re-run 'vopono sync'"
        elif [[ $seen -eq 0 ]]; then
            fail "no WireGuard config files${SERVERS:+ starting with: $SERVERS} in $CONFIG_DIR (looked for *.conf)"
        elif [[ ${#tried[@]} -gt 0 ]]; then
            fail "every server matching SERVERS (${SERVERS:-any}) was tried and none answered.$why_all"
        else
            fail "no WireGuard file in $CONFIG_DIR is safe to use, so Ghost Browser was not opened.$why_all"
        fi
    fi
    server="${pick%%$'\t'*}"
    conf="${pick#*$'\t'}"
    [[ -r $conf ]] || fail "server config missing or unreadable: $conf"
    [[ -n $CONFIG_DIR ]] && check_private "$conf" "a VPN key"
    target=(--custom "$conf" --protocol "$PROTOCOL")
    if [[ -n $AUTH_FILE ]]; then check_private "$AUTH_FILE" "a VPN password"; target+=(--auth-user-pass "$AUTH_FILE"); fi
}

make_dead_tunnel() {   # throwaway WireGuard config to 192.0.2.1 (TEST-NET-1: never answers)
    local conf="$RUN/blackhole.conf"
    {
        printf '[Interface]\nPrivateKey = %s\nAddress = 10.66.66.2/32\nDNS = 10.66.66.1\n\n' "$(wg genkey)"
        printf '[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 192.0.2.1:51820\n' "$(wg genkey | wg pubkey)"
    } > "$conf"
    chmod 600 "$conf"
    target=(--custom "$conf" --protocol Wireguard)
}

# vopono's errors can quote a config file. Hide key values (by label, and anything shaped like a
# WireGuard key: 43 base64 characters and '=') before they reach the screen or a popup.
redact() { sed -u -E 's/((private|preshared)[ _-]?key)[^,;}]*/\1 = <hidden>/Ig; s#[A-Za-z0-9+/]{43}=#<hidden>#g'; }

run_vopono() {   # $1 = log name, $2 = application string for vopono
    local log="$RUN/$1.log"
    # vopono splits the application string on spaces, so this script's own path cannot contain any.
    [[ $SELF != *[[:space:]]* ]] || fail "install this script in a path without spaces (e.g. ~/.local/bin), not: $SELF"
    # A fresh namespace name every call. vopono's own name comes from the config's contents, and every
    # NordVPN config shares one key + address, so a second window would otherwise join the first's tunnel.
    local ns="vo_gb$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    say "namespace: $ns"
    if have_tty; then
        vopono exec "${askpass[@]}" -i "$iface" --disable-ipv6 --custom-netns-name "$ns" "${target[@]}" "$2" 2>&1 | redact | tee "$log"
        return "${PIPESTATUS[0]}"
    fi
    vopono exec "${askpass[@]}" -i "$iface" --disable-ipv6 --custom-netns-name "$ns" "${target[@]}" "$2" > "$log" 2>&1
}

launch_with_retry() {   # $1 = dead-first (only --selftest-retry): attempt 1 gets a tunnel that never answers
    local attempt rc
    for (( attempt = 1; attempt <= MAX_TRIES; attempt++ )); do
        if [[ $attempt -eq 1 && ${1:-} == dead-first ]]; then
            make_dead_tunnel; server="test-dead-tunnel"
        else
            need_vpn
        fi
        tried+=("$server")
        say "attempt $attempt/$MAX_TRIES - exit: $VIA / $server (host egress: $iface) | profile: $RUN (RAM, deleted on close)"
        have_tty || notify-send -i web-browser "$TITLE" "Connecting via $server" 2>/dev/null
        rm -f -- "$RUN/tunnel-dead" "$RUN/not-tunnel"
        run_vopono launch "$SELF --inner $RUN $BROWSER $HOST_NS"
        rc=$?
        if [[ -e $RUN/not-tunnel ]]; then
            fail "SECURITY: with $server, the route to the internet was not a full tunnel through the VPN (a split-tunnel config? for WireGuard, vopono then adds no kill switch). Ghost Browser was NOT opened"
        fi
        if [[ -e $RUN/tunnel-dead ]]; then
            say "$server did not answer within ${PROBE_SECONDS}s - its namespace is gone, trying another server"
            have_tty || notify-send -i web-browser "$TITLE" "$server did not answer - trying another server" 2>/dev/null
            continue
        fi
        [[ $rc -eq 0 ]] || fail "vopono exited with an error. Last lines:"$'\n'"$(tail -n 15 "$RUN/launch.log" | redact)"
        return 0
    done
    local fix="re-run 'vopono sync', or set other SERVERS in $CONFIG_FILE"
    [[ -n $CONFIG_DIR ]] && fix="download fresh config files into $CONFIG_DIR"
    fail "no server answered after $MAX_TRIES tries (${tried[*]}). Check your VPN account, or $fix"
}

case "${1:-}" in
    "")
        launch_with_retry
        ;;
    --selftest-retry)
        say "attempt 1 uses a tunnel to 192.0.2.1 that never answers: it must be detected and replaced by a real server"
        launch_with_retry dead-first
        ;;
    --dry-run)
        need_vpn
        say "config: $([[ -e $CONFIG_FILE ]] && echo "$CONFIG_FILE" || echo "none (defaults)")"
        say "would use: $VIA / $server ($PROTOCOL), host egress: $iface"
        say "would run: vopono exec -i $iface --disable-ipv6 --custom-netns-name vo_gb<random> --custom $(basename -- "${target[1]}") --protocol $PROTOCOL $([[ -n $AUTH_FILE ]] && echo "--auth-user-pass $AUTH_FILE ")\"$SELF --inner <ram-folder> $BROWSER $HOST_NS\""
        say "dry run: nothing was built and sudo was not used"
        ;;
    --check)
        need_vpn
        host_ip="$(curl -sS -m 10 https://am.i.mullvad.net/ip)"
        say "host (outside the namespace) exits as: ${host_ip:-unknown}"
        say "namespace: $VIA / $server (host egress: $iface)"
        run_vopono check "$SELF --probe exit"
        ns_ip="$(grep -o '"ip":"[^"]*"' "$RUN/check.log" | head -n1 | cut -d'"' -f4)"
        if [[ -n $ns_ip && $ns_ip != "$host_ip" ]]; then say "PASS exit: namespace exits as $ns_ip, not the host's $host_ip"
        else say "FAIL exit: namespace IP '${ns_ip:-none}' vs host '$host_ip'"; exit 1; fi
        ;;
    --selftest)
        say "stage 1/2: plumbing - a namespace with NO VPN, curl only (never a browser)"
        target=(--provider None --protocol None --dns 1.1.1.1)
        run_vopono plumbing "$SELF --probe plumbing"
        say "stage 2/2: dead tunnel - WireGuard to 192.0.2.1, an address that never answers"
        make_dead_tunnel
        run_vopono dead "$SELF --probe dead"
        grep -q 'PASS plumbing' "$RUN/plumbing.log" && p1=PASS || p1=FAIL
        grep -q 'PASS dead-tunnel' "$RUN/dead.log" && p2=PASS || p2=FAIL
        say "RESULT: plumbing $p1 | dead-tunnel $p2"
        [[ $p1 == PASS && $p2 == PASS ]]
        ;;
    --selftest-browser)
        make_dead_tunnel
        say "opening Ghost Browser inside a dead tunnel: every page must fail to load. Close it to finish."
        run_vopono browser "$SELF --inner $RUN $BROWSER $HOST_NS --no-probe"
        ;;
    *)
        fail "unknown option: $1 (see --help)"
        ;;
esac
