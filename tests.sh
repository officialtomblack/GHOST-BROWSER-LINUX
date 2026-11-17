#!/usr/bin/env bash
# tests.sh - checks ghost-browser.sh without sudo, without a VPN account and without opening a browser.
#
#   bash tests.sh            (from anywhere; no internet needed)
#
# How: a throwaway folder gets a copy of the launcher, placeholder config files (no real keys) and a
# stand-in `vopono` that is put first on PATH. The stand-in never calls sudo and never touches the real
# vopono or its configs. "Running" a config happens in a fresh namespace with no real network
# (`unshare -rnm`) laid out the way vopono 1.0.2 lays one out (wireguard.rs add_routes, netns.rs):
# a veth default route in the main table, plus a real WireGuard device carrying the default route in
# table 51820 with "not fwmark 0xca6c lookup 51820" and "lookup main suppress_prefixlength 0" rules.
# example.com resolves from a stand-in /etc/hosts, so the launcher's tunnel check passes offline.
# Config file name -> layout:
#   dead*/blackhole*  full tunnel, but no hosts entry: the check fails like a dead VPN server
#   split*            vopono's split-tunnel layout: 1.0.0.0/8 on the WireGuard device in main, no /0
#   halfsplit*        0.0.0.0/1 + 128.0.0.0/1 on the WireGuard device in main, no /0 (no kill switch)
#   veth*             no tunnel at all, only the veth default route
#   ovpn*             OpenVPN-style: a tun device with the 0.0.0.0/1 + 128.0.0.0/1 "def1" routes
#   fail*             vopono itself fails, printing a key in its error (the popup must hide it)
#   anything else     full WireGuard tunnel
# The browser is /bin/true, or a stand-in that records where it was told to keep its files.
# Every run has a terminal (`script`) and no display, so an error can never open a popup.

set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/gb-tests.XXXXXXXX")" || exit 1
trap 'rm -rf -- "${W:?}"' EXIT
pass=0; failed=0

cp -- "$HERE/ghost-browser.sh" "$W/gb.sh"
mkdir -p "$W/bin" "$W/provider"
cat > "$W/bin/vopono" <<'EOF'
#!/usr/bin/env bash
# Stand-in for vopono (tests only).
case "$1" in
    servers)   # servers <provider> --protocol <p> --prefix <x>: same columns as the real one
        prefix=""; while [[ $# -gt 0 ]]; do [[ $1 == --prefix ]] && prefix="$2"; shift; done
        printf 'id\tprotocol\tcountry_code\tcountry\thostname\tconfig_file\n'
        for n in us1 us10 us12 ch3 ovpn5; do
            [[ $n == "$prefix"* ]] && printf '%s\tWireguard\txx\tFakeland\t%s.example\t%s\n' "$n" "$n" "$FAKE_DIR/provider/$n.conf"
        done ;;
    providers) ;;   # nothing synced
    exec)
        app="${@: -1}"; conf=""
        while [[ $# -gt 0 ]]; do [[ $1 == --custom ]] && conf="$2"; shift; done
        name="$(basename -- "$conf")"
        echo "fake-vopono: $name"
        [[ $name == fail* ]] && { echo 'Error: could not parse config: PrivateKey = SECRETKEYXYZ123='
                                  echo 'Error { input: "PresharedKey: \"PSKSECRET999\"", code: Eof }'
                                  echo 'wg: Key is not the correct length or format: `aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGVsbG8=`'
                                  exit 1; }
        hosts=yes; layout=full
        case "$name" in
            dead*|blackhole*) hosts=no ;; halfsplit*) layout=halfsplit ;; split*) layout=split ;;
            veth*) layout=veth ;; ovpn*) layout=ovpn ;;
        esac
        { cat /etc/hosts; echo "192.0.2.80 example.com"; } > "$FAKE_DIR/hosts"
        HOSTS="$hosts" LAYOUT="$layout" unshare -rnm bash -c '
            set -e
            ip link set lo up
            ip link add vo_x_d type veth peer name vo_x_s; ip link set vo_x_d up; ip link set vo_x_s up
            ip addr add 10.200.1.2/24 dev vo_x_d; ip route add default via 10.200.1.1 dev vo_x_d
            case $LAYOUT in
                full|split|halfsplit)
                    ip link add vo_gbtest type wireguard; ip link set vo_gbtest up
                    ip addr add 10.9.9.2/32 dev vo_gbtest ;;
            esac
            case $LAYOUT in
                full)      ip route add default dev vo_gbtest table 51820
                           ip rule add not fwmark 0xca6c table 51820
                           ip rule add table main suppress_prefixlength 0 ;;
                split)     ip route add 1.0.0.0/8 dev vo_gbtest ;;
                halfsplit) ip route add 0.0.0.0/1 dev vo_gbtest; ip route add 128.0.0.0/1 dev vo_gbtest ;;
                ovpn)      ip tuntap add dev tun0 mode tun; ip link set tun0 up; ip addr add 10.8.0.2/32 dev tun0
                           ip route add 0.0.0.0/1 dev tun0; ip route add 128.0.0.0/1 dev tun0 ;;
            esac
            [[ $HOSTS == yes ]] && mount --bind "$FAKE_DIR/hosts" /etc/hosts
            set +e
            exec bash -c "$1"' _ "$app" ;;
    *) echo "fake vopono: unsupported: $*" >&2; exit 2 ;;
esac
EOF
chmod 755 "$W/bin/vopono"
cat > "$W/bin/fakebrowser" <<'EOF'
#!/usr/bin/env bash
# Stand-in browser (tests only): records where it was told to keep its files, then exits.
{ echo "HOME=$HOME"; echo "TMPDIR=${TMPDIR:-unset}"; [[ -d ${TMPDIR:-/nonexistent} ]] && echo tmpdir-exists; } > "$FAKE_DIR/browser-env"
EOF
chmod 755 "$W/bin/fakebrowser"
WG_PLACEHOLDER=$'[Interface]\n# placeholder, no key\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n'
# Provider files are written by vopono, and the launcher must never read them: these would fail every
# file check, so provider mode working with them proves no check reads them.
for n in us1 us10 us12 ch3 ovpn5; do printf '[Interface]\nup /bin/sh\n' > "$W/provider/$n.conf"; done

folder() {   # $1 = folder name, rest = file names to create in it (placeholder content, mode 600)
    local d="$W/$1"; shift
    mkdir -p "$d"; chmod 700 "$d"
    local f; for f in "$@"; do
        printf '%s' "$WG_PLACEHOLDER" > "$d/$f"
        chmod 600 "$d/$f"
    done
}
put() { printf '%s\n' "${@:2}" > "$1"; chmod 600 "$1"; }   # $1 = file, rest = its lines

# out <config lines...> -- <launcher args>: runs the launcher, prints what it printed
out() {
    local cfg=() args=()
    while [[ $# -gt 0 && $1 != -- ]]; do cfg+=("$1"); shift; done; shift
    args=("$@")
    printf '%s\n' "${cfg[@]}" > "$W/cfg"
    env -u DISPLAY -u WAYLAND_DISPLAY GHOST_BROWSER_CONFIG="$W/cfg" FAKE_DIR="$W" PATH="$W/bin:$PATH" \
        timeout --foreground 90 script -qec "$W/gb.sh ${args[*]}" /dev/null < /dev/null 2>&1 | tr -d '\r'
}
check() {   # $1 = name, $2 = regex that must appear, $3 = output
    if grep -qE -- "$2" <<< "$3"; then pass=$((pass + 1)); echo "PASS  $1"
    else failed=$((failed + 1)); echo "FAIL  $1   (expected: $2)"; tail -n 6 <<< "$3" | sed 's/^/        /'; fi
}
check_not() {   # $1 = name, $2 = regex that must NOT appear, $3 = output
    if grep -qE -- "$2" <<< "$3"; then failed=$((failed + 1)); echo "FAIL  $1   (must not show: $2)"; grep -E -- "$2" <<< "$3" | head -n 3 | sed 's/^/        /'
    else pass=$((pass + 1)); echo "PASS  $1"; fi
}
picked() { sed -n 's/.*would use: .* \/ \(.*\) (\(Wireguard\|OpenVpn\)).*/\1/p' <<< "$1"; }

RB="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
runs_before="$(ls -d "$RB"/ghost-browser.* 2>/dev/null | sort)"

echo "== config file"
folder wg us-nyc.conf us-lax.conf de-fra.conf "uk lon.conf"; printf 'x\n' > "$W/wg/notes.txt"
chmod 644 "$W/wg/de-fra.conf"
folder empty
folder ovpn se-sto.conf; printf 'client\nup /bin/sh\n' > "$W/ovpn/ch-zrh.ovpn"; printf 'u\np\n' > "$W/ovpn/login.txt"; chmod 644 "$W/ovpn/login.txt"
folder "has space" "my server.conf"
check "PROVIDER and CONFIG_DIR together"   'ERROR: set PROVIDER or CONFIG_DIR .*not both' "$(out PROVIDER=FakeVPN "CONFIG_DIR=$W/wg" -- --dry-run)"
check "CONFIG_DIR not a folder"            'ERROR: CONFIG_DIR is not a folder'           "$(out "CONFIG_DIR=$W/nope" -- --dry-run)"
check "empty folder"                       'ERROR: no WireGuard config files'            "$(out "CONFIG_DIR=$W/empty" -- --dry-run)"
check "prefix * is literal"                'ERROR: no WireGuard config files starting with: \*' "$(out "CONFIG_DIR=$W/wg" 'SERVERS=*' -- --dry-run)"
check "readable key file warns"            'WARNING: .*de-fra.conf holds a VPN key'       "$(out "CONFIG_DIR=$W/wg" SERVERS=de -- --dry-run)"
check "AUTH_FILE with WireGuard"           'ERROR: AUTH_FILE is for OpenVpn only'         "$(out "CONFIG_DIR=$W/wg" "AUTH_FILE=$W/ovpn/login.txt" -- --dry-run)"
o="$(out PROVIDER=FakeVPN SERVERS=us PROTOCOL=openvpn "AUTH_FILE=$W/ovpn/login.txt" -- --dry-run)"
check "OpenVPN login passed to vopono"     '--auth-user-pass .*login.txt'                 "$o"
check "readable login file warns"          'WARNING: .*login.txt holds a VPN password'    "$o"
check "spaces in folder and file names"    'would use: .* / my server \(Wireguard\)'      "$(out "CONFIG_DIR=\"$W/has space\"" -- --dry-run)"
check "~/ is expanded"                     "is not a folder: $HOME/gb-tests-no-such-folder" "$(out 'CONFIG_DIR=~/gb-tests-no-such-folder' -- --dry-run)"
check "nothing set"                        'ERROR: set PROVIDER and SERVERS \(or CONFIG_DIR\)' "$(out PROTOCOL=Wireguard -- --dry-run)"
check "unknown key"                        "ERROR: .* line 1: unknown setting 'PROVDER'"  "$(out PROVDER=x -- --dry-run)"
check "bad protocol"                       'ERROR: .*PROTOCOL must be Wireguard or OpenVpn' "$(out PROTOCOL=ipsec -- --dry-run)"
check "line without ="                     'ERROR: .* line 2: expected KEY=VALUE'        "$(out '# comment' 'PROVIDER FakeVPN' -- --dry-run)"
o="$(out PROVIDER=FakeVPN SERVERS=us -- --dry-run)"
check "provider mode picks a synced server" 'would use: FakeVPN / us1[02]? \(Wireguard\)' "$o"
check_not "provider mode never reads the files (they would fail every check)" 'WARNING: skipping|safe to use' "$o"
check "provider prefix with no servers"    "ERROR: no synced FakeVPN Wireguard servers match" "$(out PROVIDER=FakeVPN SERVERS=zz -- --dry-run)"

picks=""; for _ in $(seq 10); do picks+="$(picked "$(out "CONFIG_DIR=$W/wg" SERVERS=us -- --dry-run)")"$'\n'; done
check_not "SERVERS=us picks only us- files"  '^(de-fra|uk lon)$' "$picks"
picks=""; for _ in $(seq 16); do picks+="$(picked "$(out "CONFIG_DIR=$W/wg" -- --dry-run)")"$'\n'; done
check_not "non-.conf files never picked"     '^notes$' "$picks"
o="$(out "CONFIG_DIR=$W/ovpn" PROTOCOL=OpenVpn -- --dry-run)"
check "CONFIG_DIR refuses OpenVPN (it could run programs as root)" 'ERROR: CONFIG_DIR takes WireGuard files only' "$o"
check_not "...and never picks an .ovpn file"     'would use' "$o"

o="$(out PROVIDER=FakeVPN SERVERS=us -- --init)"   # config exists: must be left alone
check "--init never overwrites"            'config already exists, left alone' "$o"
rm -f -- "$W/new.cfg"
o="$(GHOST_BROWSER_CONFIG="$W/new.cfg" PATH="$W/bin:$PATH" env -u DISPLAY timeout --foreground 30 script -qec "$W/gb.sh --init" /dev/null < /dev/null 2>&1 | tr -d '\r')"
check "--init writes a starter config"     'wrote a starter config' "$o"
check "starter config has both modes"      '^#CONFIG_DIR=' "$(cat "$W/new.cfg" 2>/dev/null)"

echo "== dead-server retry (stand-in vopono)"
if ! unshare -rn true 2>/dev/null; then
    echo "SKIP  retry cases: 'unshare -rn' is not allowed on this system (user namespaces off)"
else
    folder three "dead one.conf" dead-two.conf good.conf
    for i in 1 2 3 4; do
        o="$(out "CONFIG_DIR=$W/three" BROWSER=/bin/true --)"
        check "run $i ends on the good server"  'fake-vopono: good.conf' "$o"
        check_not "run $i: no ERROR"            'ERROR' "$o"
        dup="$(grep -o 'fake-vopono: .*' <<< "$o" | sort | uniq -d)"
        check_not "run $i: no server tried twice" '.' "$dup"
    done
    folder alldead dead-a.conf dead-b.conf dead-c.conf dead-d.conf
    check "all dead: gives up after 3"         'ERROR: no server answered after 3 tries' "$(out "CONFIG_DIR=$W/alldead" BROWSER=/bin/true --)"

    # Review finding 1 (2026-11-12): with several prefixes, a try must move on to another prefix
    # instead of giving up while an untried server remains.
    folder twoprefix dead-ch.conf us-good.conf
    bad=0; for _ in $(seq 10); do
        o="$(out "CONFIG_DIR=$W/twoprefix" 'SERVERS=dead us' BROWSER=/bin/true --)"
        grep -q 'fake-vopono: us-good.conf' <<< "$o" && ! grep -q ERROR <<< "$o" || bad=$((bad + 1))
    done
    check "two prefixes: 10 of 10 reach the good one" '^0$' "$bad"
    bad=0; warned=0; for _ in $(seq 10); do
        o="$(out "CONFIG_DIR=$W/twoprefix" 'SERVERS=us zz' BROWSER=/bin/true --)"
        grep -q 'fake-vopono: us-good.conf' <<< "$o" && ! grep -q ERROR <<< "$o" || bad=$((bad + 1))
        grep -q "WARNING: nothing matches SERVERS prefix.*zz" <<< "$o" && warned=$((warned + 1))
    done
    check "typo prefix: 10 of 10 still launch"  '^0$' "$bad"
    check "typo prefix: named in a warning every time (10 of 10)" '^10$' "$warned"

    if command -v wg >/dev/null; then
        check "--selftest-retry swaps the dead test tunnel" 'test-dead-tunnel did not answer.*' \
            "$(out "CONFIG_DIR=$W/three" SERVERS=good BROWSER=/bin/true -- --selftest-retry)"
    else
        echo "SKIP  --selftest-retry: wireguard-tools (wg) not installed"
    fi
fi

echo "== safety checks (split-tunnel VPN files, OpenVPN as root, temp files on disk)"
# One file per folder, so each case is deterministic. ok_wg / bad_wg: name, then the file's lines after a
# standard "[Interface]" + placeholder line. raw_wg: name, then the whole file.
one() { local d="$W/case-$1"; rm -rf -- "$d"; mkdir -p "$d"; chmod 700 "$d"; put "$d/$2" "${@:3}"; echo "$d"; }
ok_wg()  { local d; d="$(one "$1" "$1.conf" '[Interface]' 'PrivateKey = placeholder' "${@:2}")"; check "VPN file: accepted: $1" "would use: .* / $1 \(Wireguard\)" "$(out "CONFIG_DIR=$d" -- --dry-run)"; }
bad_wg() { local d; d="$(one "$1" "$1.conf" '[Interface]' 'PrivateKey = placeholder' "${@:2}")"; check "VPN file: refused: $1" "ERROR: no WireGuard file in .* is safe to use, so Ghost Browser was not opened\. Refused as unsafe \(1\): $1: " "$(out "CONFIG_DIR=$d" -- --dry-run)"; }
raw_wg() { local d; d="$(one "$1" "$1.conf" "${@:2}")"; check "VPN file: refused: $1" "Refused as unsafe \(1\): $1: " "$(out "CONFIG_DIR=$d" -- --dry-run)"; }

# WireGuard files: only the exact form vopono reads, and an exact 0.0.0.0/0 in the one [Peer].
ok_wg  wg-plain       '[Peer]' 'AllowedIPs = 0.0.0.0/0, ::/0'
ok_wg  wg-nospace     '[Peer]' 'AllowedIPs=0.0.0.0/0'
ok_wg  wg-v6first     '[Peer]' 'AllowedIPs = ::/0,0.0.0.0/0'
ok_wg  wg-comment     '[Peer] # the server' 'AllowedIPs = 0.0.0.0/0 # everything' '# a comment line'
ok_wg  wg-crlf        $'[Peer]\r' $'AllowedIPs = 0.0.0.0/0\r'
ok_wg  wg-twolines    '[Peer]' 'AllowedIPs = 10.0.0.0/8' 'AllowedIPs = 0.0.0.0/0'
bad_wg wg-halfpair    '[Peer]' 'AllowedIPs = 0.0.0.0/1, 128.0.0.0/1'
bad_wg wg-in-comment  '[Peer]' 'AllowedIPs = 0.0.0.0/1, 128.0.0.0/1 # 0.0.0.0/0'
bad_wg wg-interface   'AllowedIPs = 0.0.0.0/0' '[Peer]' 'AllowedIPs = 10.0.0.0/8'
bad_wg wg-lowercase   '[Peer]' 'allowedips = 0.0.0.0/0'
bad_wg wg-indented    '[Peer]' '  AllowedIPs = 0.0.0.0/0'
bad_wg wg-spaceline   '[Peer]' 'AllowedIPs = 0.0.0.0/0' '   '
bad_wg wg-lookalike   '[Peer]' 'AllowedIPs = 10.0.0.0/0x, 100.0.0.0/0'
bad_wg wg-v6only      '[Peer]' 'AllowedIPs = ::/0'
bad_wg wg-twopeers    '[Peer]' 'AllowedIPs = 0.0.0.0/0' '[Peer]' 'AllowedIPs = 0.0.0.0/0'
bad_wg wg-nopeer      'AllowedIPs = 0.0.0.0/0'
bad_wg wg-othersect   '[Peer]' 'AllowedIPs = 10.0.0.0/8' '[Other] # note' 'AllowedIPs = 0.0.0.0/0'
bad_wg wg-unicode     '[Peer]' 'AllowedIPs = 10.0.0.0/8' $'[Pe\xc3\xa9r]' 'AllowedIPs = 0.0.0.0/0'
bad_wg wg-headertext  '[Peer]x' 'AllowedIPs = 0.0.0.0/0'
bad_wg wg-barehash    '[Peer]' 'AllowedIPs = 0.0.0.0/0' '#'
bad_wg wg-barehashcr  '[Peer]' $'#\r' 'AllowedIPs = 0.0.0.0/0'
bad_wg wg-headerhash  '[Peer] #' 'AllowedIPs = 0.0.0.0/0'
bad_wg wg-nonascii    '[Peer]' 'AllowedIPs = 0.0.0.0/0' $'# caf\xc3\xa9'
bad_wg wg-control     '[Peer]' 'AllowedIPs = 0.0.0.0/0' $'# bell\x07'
bad_wg wg-twoifaces   '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0'
raw_wg wg-noiface     '[Peer]' 'AllowedIPs = 0.0.0.0/0'
raw_wg wg-ifacetext   '[Interface]x' '[Peer]' 'AllowedIPs = 0.0.0.0/0'
# The reason must name the actual problem (so a rule cannot be removed while another hides it).
d="$(one wg-why-ascii wg-why-ascii.conf '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0' $'# caf\xc3\xa9')"
check "VPN file: reason: non-ASCII byte in a comment" 'wg-why-ascii: line 4 has a non-ASCII or control character' "$(out "CONFIG_DIR=$d" -- --dry-run)"
d="$(one wg-why-indent wg-why-indent.conf '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0' '  Endpoint = 192.0.2.1:51820')"
check "VPN file: reason: an indented key" 'wg-why-indent: line 4 is not a "Key = value" line' "$(out "CONFIG_DIR=$d" -- --dry-run)"
d="$(one wg-why-two wg-why-two.conf '[Interface]' '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0')"
check "VPN file: reason: two [Interface] sections" 'wg-why-two: it needs exactly one \[Interface\] and one \[Peer\] section \(it has 2 and 1\)' "$(out "CONFIG_DIR=$d" -- --dry-run)"
raw_wg wg-keyfirst    'AllowedIPs = 0.0.0.0/0' '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0'
d="$(one wg-nul wg-nul.conf '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0')"; printf 'x\000y\n' >> "$d/wg-nul.conf"
check "VPN file: refused: a file with NUL bytes" 'Refused as unsafe \(1\): wg-nul: it contains NUL bytes' "$(out "CONFIG_DIR=$d" -- --dry-run)"
o="$(out "CONFIG_DIR=$W/case-wg-halfpair" -- --dry-run)"
check_not "VPN file: never prints a file's contents" 'placeholder|128\.0\.0\.0' "$o"

# OpenVPN: CONFIG_DIR takes no OpenVPN files at all (openvpn's syntax had three ways around a checker).
d="$(one ov-evil ov-evil.ovpn 'client' '<ca>' '</ca>x' 'plugin /tmp/x.so' '<ca>' '</ca>' 'setenv opt plugin /tmp/y.so')"
check "OpenVPN: an OpenVPN folder is refused before any file is read" 'ERROR: CONFIG_DIR takes WireGuard files only' "$(out "CONFIG_DIR=$d" PROTOCOL=OpenVpn -- --dry-run)"

# The file and the folder must be yours and writable only by you; unreadable files are refused.
d="$(one perm-dir perm-dir.conf '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0')"; chmod 770 "$d"
check "refused: a folder other users can write to" 'Refused as unsafe \(1\): perm-dir: it, or the folder .* can be changed by other users' "$(out "CONFIG_DIR=$d" -- --dry-run)"
d="$(one perm-file perm-file.conf '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0')"; chmod 622 "$d/perm-file.conf"
check "refused: a file other users can write to" 'Refused as unsafe \(1\): perm-file: it, or the folder .* can be changed by other users' "$(out "CONFIG_DIR=$d" -- --dry-run)"
d="$(one perm-none perm-none.conf '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0')"; chmod 000 "$d/perm-none.conf"
check "refused: a file you cannot read" 'Refused as unsafe \(1\): perm-none: it cannot be read' "$(out "CONFIG_DIR=$d" -- --dry-run)"
chmod 600 "$d/perm-none.conf"
d="$(one owner-x owner-x.conf '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0')"
printf '#!/usr/bin/env bash\nif [[ $* == *%%u*owner-x.conf* ]]; then echo 0; else exec /usr/bin/stat "$@"; fi\n' > "$W/bin/stat"; chmod 755 "$W/bin/stat"
check "refused: a file someone else owns (stand-in stat says root)" 'Refused as unsafe \(1\): owner-x: it, or the folder .* is not owned by you' "$(out "CONFIG_DIR=$d" -- --dry-run)"
d="$(one owner-d owner-d.conf '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/0')"
printf '#!/usr/bin/env bash\nif [[ $* == *%%u*case-owner-d && $* != *.conf ]]; then echo 0; else exec /usr/bin/stat "$@"; fi\n' > "$W/bin/stat"; chmod 755 "$W/bin/stat"
check "refused: a folder someone else owns (stand-in stat says root)" 'Refused as unsafe \(1\): owner-d: it, or the folder .* is not owned by you' "$(out "CONFIG_DIR=$d" -- --dry-run)"
rm -f -- "$W/bin/stat"

# A prefix whose files are all unsafe must not sink the launch while another prefix has a safe one.
folder twoprefix2 us-good.conf; put "$W/twoprefix2/bad-half.conf" '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/1, 128.0.0.0/1'
bad=0; for _ in $(seq 10); do
    o="$(out "CONFIG_DIR=$W/twoprefix2" 'SERVERS=bad us' -- --dry-run)"
    grep -q 'would use: .* / us-good ' <<< "$o" && ! grep -q ERROR <<< "$o" || bad=$((bad + 1))
done
check "an all-unsafe prefix: 10 of 10 still pick the safe one" '^0$' "$bad"
# The error lists at most 5 reasons, so a popup stays readable.
folder many; for i in 1 2 3 4 5 6 7; do put "$W/many/bad$i.conf" '[Interface]' '[Peer]' 'AllowedIPs = 10.0.0.0/8'; done
check "many refusals: the error names 5 and counts the rest" 'Refused as unsafe \(7\): (bad[0-9]: [^;]*; ){5}and 2 more\.' "$(out "CONFIG_DIR=$W/many" -- --dry-run)"

if unshare -rn true 2>/dev/null; then
    # A file refused as unsafe is never run, not even on a later try after a dead server.
    # A stand-in shuf keeps the order, so attempt 1 is always dead-a and half must be checked on attempt 2.
    folder retryref dead-a.conf; put "$W/retryref/half.conf" '[Interface]' '[Peer]' 'AllowedIPs = 0.0.0.0/1, 128.0.0.0/1'
    printf '#!/usr/bin/env bash\nif [[ ${1:-} == -e ]]; then shift; [[ ${1:-} == -- ]] && shift; printf "%%s\\n" "$@"; else cat; fi\n' > "$W/bin/shuf"; chmod 755 "$W/bin/shuf"
    o="$(out "CONFIG_DIR=$W/retryref" BROWSER=/bin/true --)"
    rm -f -- "$W/bin/shuf"
    check     "retry order is fixed: dead-a is tried first"   'fake-vopono: dead-a.conf' "$o"
    check_not "a refused file is never run on a retry"         'fake-vopono: half.conf' "$o"
    check     "...and it is refused once, not once per try"    'Refused as unsafe \(1\): half: ' "$o"
fi
# vopono's own error text is shown in the popup; any key it quotes must be hidden.
folder failing fail-one.conf
o="$(out "CONFIG_DIR=$W/failing" BROWSER=/bin/true --)"
check "vopono's error is shown"                 'ERROR: vopono exited with an error' "$o"
check_not "...with key values hidden, on screen and in the error" 'SECRETKEYXYZ123|PSKSECRET999|aGVsbG9oZWxsb2hl' "$o"

if unshare -rnm true 2>/dev/null && unshare -rn ip link add t0 type wireguard 2>/dev/null; then
    # The route check at run time, on vopono-like namespaces: the launcher's own route check inside the namespace.
    for layout in split halfsplit veth; do
        folder "rt-$layout" "$layout-a.conf" "$layout-b.conf"; rm -f -- "$W/browser-env"
        o="$(out "CONFIG_DIR=$W/rt-$layout" "BROWSER=$W/bin/fakebrowser" --)"
        check "route check ($layout): stops with SECURITY" "ERROR: SECURITY: with $layout-[ab], the route to the internet was not a full tunnel" "$o"
        check_not "route check ($layout): the browser never started" '.' "$(cat "$W/browser-env" 2>/dev/null)"
        check_not "route check ($layout): no second server tried" 'attempt 2/' "$o"
    done
    folder rt-full good.conf; rm -f -- "$W/browser-env"
    out "CONFIG_DIR=$W/rt-full" "BROWSER=$W/bin/fakebrowser" -- >/dev/null
    env_seen="$(cat "$W/browser-env" 2>/dev/null)"
    check "full WireGuard tunnel (vopono layout): the browser starts" '^HOME=' "$env_seen"
    rm -f -- "$W/browser-env"
    out PROVIDER=FakeVPN SERVERS=ovpn PROTOCOL=OpenVpn "BROWSER=$W/bin/fakebrowser" -- >/dev/null
    check "OpenVPN with def1 /1 routes: the browser starts (vopono's OpenVPN kill switch is always on)" '^HOME=' "$(cat "$W/browser-env" 2>/dev/null)"
    # The browser's temp folder (downloads start there) is inside the RAM folder, not /tmp.
    check "RAM: TMPDIR is in the RAM run folder"  "^TMPDIR=${RB}/ghost-browser\.[A-Za-z0-9]{8}/tmp\$" "$env_seen"
    check "RAM: ...and it exists"                 '^tmpdir-exists$' "$env_seen"
    check "RAM: HOME is in the RAM run folder"    "^HOME=${RB}/ghost-browser\.[A-Za-z0-9]{8}/home\$" "$env_seen"
else
    echo "SKIP  run-time route and RAM cases: 'unshare -rnm' or a WireGuard device is not allowed on this system"
fi

# --dry-run and friends must print even when their output is piped (no terminal).
printf '%s\n' "CONFIG_DIR=$W/wg" > "$W/cfg"
o="$(env -u DISPLAY GHOST_BROWSER_CONFIG="$W/cfg" FAKE_DIR="$W" PATH="$W/bin:$PATH" timeout 30 "$W/gb.sh" --dry-run < /dev/null 2>&1 | cat)"
check "--dry-run prints when piped" 'would use: ' "$o"

echo "== guards"
mkdir -p "$W/dir with space"; cp -- "$W/gb.sh" "$W/dir with space/gb.sh"
printf '%s\n' "CONFIG_DIR=$W/three" BROWSER=/bin/true > "$W/cfg"
o="$(env -u DISPLAY GHOST_BROWSER_CONFIG="$W/cfg" FAKE_DIR="$W" PATH="$W/bin:$PATH" timeout --foreground 30 script -qec "'$W/dir with space/gb.sh'" /dev/null < /dev/null 2>&1 | tr -d '\r')"
check "refuses to run from a path with spaces" 'ERROR: install this script in a path without spaces' "$o"
o="$(env -u DISPLAY timeout --foreground 30 script -qec "$W/gb.sh --inner /tmp/not-a-run-folder /bin/true" /dev/null < /dev/null 2>&1 | tr -d '\r')"
check "inner refuses an odd run folder"    'ERROR: refusing odd run folder' "$o"
# --inner called on the host's own network must never start a browser.
rd="$(mktemp -d "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ghost-browser.XXXXXXXX")"
hns="$(readlink /proc/self/ns/net | tr -dc 0-9)"
o="$(env -u DISPLAY timeout --foreground 30 script -qec "$W/gb.sh --inner $rd $W/bin/fakebrowser $hns" /dev/null < /dev/null 2>&1 | tr -d '\r')"
check "inner refuses the host's own network" 'ERROR: refusing to start the browser: this is not a separate VPN namespace' "$o"
o="$(env -u DISPLAY timeout --foreground 30 script -qec "$W/gb.sh --inner $rd $W/bin/fakebrowser" /dev/null < /dev/null 2>&1 | tr -d '\r')"
check "inner refuses a missing namespace id" 'ERROR: refusing to start the browser' "$o"
o="$(env -u DISPLAY unshare -rm bash -c 'mount -t tmpfs none /proc && "$0" --inner "$1" "$2" "$3"' "$W/gb.sh" "$rd" "$W/bin/fakebrowser" "$hns" 2>&1 < /dev/null)"
check "inner refuses when its namespace id cannot be read" 'ERROR: refusing to start the browser' "$o"
rm -rf -- "${rd:?}"

left="$(comm -13 <(printf '%s\n' "$runs_before") <(ls -d "$RB"/ghost-browser.* 2>/dev/null | sort) | grep -v '^$')"
check_not "no RAM folders left behind by the tests" '.' "$left"

echo "== $pass passed, $failed failed"
[[ $failed -eq 0 ]]
