#!/usr/bin/env bash
# Offline tests for install.sh: no sudo, no internet, nothing outside a temp folder is changed
# (the installer's root-owned temp folder /tmp/ghost-browser-install.* is created through a stand-in and removed again).
# Stand-ins replace sudo, apt-get, dpkg, dpkg-query, pgrep, ip, xdg-user-dir, gio, update-desktop-database,
# zenity, notify-send and vopono; downloads come from fixtures. gpg is real. Mullvad's public key ships in
# test-fixtures/; an attacker key is made fresh for each run.
#   bash install-tests.sh
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/install.sh"
MKEY="$HERE/test-fixtures/mullvad-keyring.asc"
T="$(mktemp -d)"
trap 'cat "$T"/sys.*/securedirs 2>/dev/null | while read -r d; do [[ $d == /tmp/ghost-browser-install.* && -d $d ]] && rm -r -- "$d"; done; for h in "$T"/gpg-*; do [[ -d $h ]] && gpgconf --homedir "$h" --kill all >/dev/null 2>&1; done; [[ -n ${KEEP:-} ]] && echo "kept: $T" || rm -rf -- "$T"' EXIT
exec < /dev/null                                            # nothing here may read the terminal
unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS     # or reach the desktop
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME GHOST_BROWSER_CONFIG   # or the real config
umask 022
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"
pass=0; failn=0
ok()  { pass=$((pass + 1)); }
bad() { failn=$((failn + 1)); printf 'FAIL: %s\n' "$*"; }
check() { local name="$1"; shift; if "$@"; then ok; else bad "$name"; fi; }
command -v gpg >/dev/null || { echo "FAIL: gpg is needed"; exit 1; }
[[ -r $MKEY ]] || { echo "FAIL: missing $MKEY"; exit 1; }

# ---------- keys: Mullvad's real public key, a fresh attacker key, and tricks built from them ----------
EG="$T/gpg-evil"; mkdir -m 700 "$EG"
gpg --homedir "$EG" --batch --quiet --passphrase '' --quick-gen-key 'Evil <e@x>' ed25519 sign never 2>/dev/null
gpg --homedir "$EG" --batch --export --armor > "$T/evil.asc"
gpg --homedir "$EG" --batch --pinentry-mode loopback --passphrase '' --export-secret-keys --armor > "$T/evil-secret.asc"
[[ -s $T/evil.asc && -s $T/evil-secret.asc ]] || { echo "FAIL: could not make a test key"; exit 1; }
{ cat "$MKEY"; echo "-----BEGIN NOT A PGP BLOCK-----"; echo; gpg --homedir "$EG" --batch --export | base64; echo "-----END NOT A PGP BLOCK-----"; } > "$T/hidden.asc"
cat "$MKEY" "$T/evil.asc" > "$T/two.asc"
cat "$MKEY" "$T/evil-secret.asc" > "$T/secret.asc"
# The checksum-trailer trick: one armored block, Mullvad's key and its checksum line, then an attacker key.
{ sed -n '1,/^=/p' "$MKEY"; gpg --homedir "$EG" --batch --export | base64 -w 64; echo "-----END PGP PUBLIC KEY BLOCK-----"; } > "$T/crc.asc"
# gpg's own clean export of Mullvad's key, made here without the installer's code.
CG="$T/gpg-canon"; mkdir -m 700 "$CG"
gpg --homedir "$CG" --batch --quiet --import "$MKEY" 2>/dev/null
CANON="$T/canon.asc"; gpg --homedir "$CG" --batch --export --armor A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF > "$CANON"
[[ -s $CANON ]] || { echo "FAIL: canonical key"; exit 1; }

# ---------- stand-in commands ----------
SB="$T/bin"; mkdir -p "$SB"
cat > "$SB/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$FAKE/log"
[[ ${FAKE_SUDO_FAIL:-0} == 1 ]] && { echo "sudo: denied" >&2; exit 1; }
while [[ ${1:-} == -* ]]; do [[ $1 == -v ]] && exit 0; shift; done
if [[ ${1:-} == install ]]; then   # tests run as a normal user: drop -o root -g root
    a=(); shift; while (( $# )); do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
    install "${a[@]}" || exit
    dest="${a[${#a[@]}-1]}"
    [[ -n ${FAKE_TAMPER:-} && $dest == *$FAKE_TAMPER* ]] && echo "tampered" >> "$dest"   # root's copy changed
    exit 0
fi
if [[ ${1:-} == mktemp ]]; then d="$("$@")" || exit; echo "$d" >> "$FAKE/securedirs"; echo "$d"; exit 0; fi
exec "$@"
EOF
cat > "$SB/apt-get" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == indextargets ]]; then   # the real apt, reading only the fake system's sources
    mkdir -p "$FAKE/lists/partial" "$FAKE/cache"
    [[ ${LC_ALL:-} == C ]] || { echo "E: Die Liste der Quellen konnte nicht gelesen werden." >&2; exit 100; }   # parsed output must be asked for in C
    : > "$FAKE/apt.conf"; exec env APT_CONFIG="$FAKE/apt.conf" /usr/bin/apt-get -o Dir::Etc::sourcelist="$FAKE/etc/apt/sources.list" -o Dir::Etc::sourceparts="$FAKE/etc/apt/sources.list.d" \
        -o Dir::State::lists="$FAKE/lists" -o Dir::Cache="$FAKE/cache" "$@"
fi
echo "apt-get $*" >> "$FAKE/log"
[[ ${1:-} == update && $* == *sourceparts=-* && ${FAKE_UPDATE_FAIL:-0} == 1 ]] && exit 100
[[ ${1:-} == update ]] && exit 0
shift; for p in "$@"; do
    case "$p" in
        -*) ;;
        /*.deb) [[ -f $p ]] || exit 100; echo "$p $(sha256sum < "$p" | cut -c1-64)" >> "$FAKE/debs"; echo "vopono 1.0.2-1" >> "$FAKE/db" ;;
        *) echo "${p%%=*} 1.0-test" >> "$FAKE/db" ;;
    esac
done
EOF
cat > "$SB/dpkg-query" <<'EOF'
#!/usr/bin/env bash
awk -v p="${!#}" '$1 == p {v = $2; s = ($3 == "" ? "installed" : $3)} END {if (v != "") printf "%s %s", s, v}' "$FAKE/db" 2>/dev/null
exit 0
EOF
cat > "$SB/apt-cache" <<'EOF'
#!/usr/bin/env bash
label="Installationskandidat:"; [[ ${LC_ALL:-} == C ]] && label="Candidate:"   # translated unless asked for in C
case "$1" in
    policy)  echo "mullvad-browser:"; echo "  $label ${FAKE_CANDIDATE:-16.0.1-1}" ;;
    madison) if [[ -f $FAKE/madison ]]; then cat "$FAKE/madison"
             else echo " mullvad-browser |   16.0.1-1 | https://repository.mullvad.net/deb/stable stable/main amd64 Packages"; fi ;;
esac
EOF
cat > "$SB/dpkg" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --print-architecture ]] && { echo "${FAKE_ARCH:-amd64}"; exit 0; }
exit 1
EOF
cat > "$SB/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ -s $FAKE/procs ]] && grep -qE -- "${!#}" "$FAKE/procs"
EOF
cat > "$SB/ip" <<'EOF'
#!/bin/sh
[ "$1 $2" = "netns list" ] && cat "$FAKE/netns" 2>/dev/null
exit 0
EOF
printf '#!/bin/sh\necho "$HOME/Desktop"\n' > "$SB/xdg-user-dir"
for c in gio update-desktop-database zenity notify-send; do printf '#!/bin/sh\necho "%s $*" >> "$FAKE/log"\nexit 0\n' "$c" > "$SB/$c"; done
printf '#!/bin/sh\necho "vopono $*" >> "$FAKE/log"\n[ "$1" = sync ] && exit "${FAKE_SYNC_RC:-0}"\nexit 1\n' > "$SB/vopono"
cat > "$SB/id" <<'EOF'
#!/bin/sh
if [ "$1" = -u ] && [ "${FAKE_ROOT:-0}" = 1 ]; then echo 0; else exec /usr/bin/id "$@"; fi
EOF
chmod 755 "$SB"/*

# ---------- one fresh fake system per test ----------
SYSN=0
newsys() {
    SYSN=$((SYSN + 1)); FAKE="$T/sys.$SYSN"; export FAKE
    mkdir -p "$FAKE/home" "$FAKE/etc/apt/sources.list.d" "$FAKE/keyrings" "$FAKE/fx"
    mkdir "$FAKE/home"/Desktop
    : > "$FAKE/log"; : > "$FAKE/db"; : > "$FAKE/debs"; : > "$FAKE/procs"; : > "$FAKE/netns"
    printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\n' > "$FAKE/os-release"; : > "$FAKE/etc/apt/sources.list"; : > "$FAKE/securedirs"
    printf 'fake vopono package\n' > "$FAKE/fx/vopono.deb"
    cp "$MKEY" "$FAKE/fx/key.asc"
    D="$FAKE/etc/apt/sources.list.d"
    unset FAKE_ARCH FAKE_ROOT FAKE_SUDO_FAIL FAKE_SWAP FAKE_TAMPER FAKE_CANDIDATE FAKE_OWNER FAKE_UPDATE_FAIL
    K="$FAKE/keyrings/mullvad-keyring.asc"; GOODLINE="deb [signed-by=$K arch=amd64] https://repository.mullvad.net/deb/stable stable main"
}
GOOD_DEB_SHA="$(printf 'fake vopono package\n' | sha256sum | cut -c1-64)"
# inst ARGS...: install.sh's main against the fake system; output in $FAKE/out, exit code in $rc.
inst() {
    ( export HOME="$FAKE/home" PATH="$SB:$PATH"
      source "$INSTALLER"
      KEYRING="$FAKE/keyrings/mullvad-keyring.asc"; APT_LIST="$FAKE/etc/apt/sources.list.d/mullvad.list"
      APT_SOURCES=("$FAKE/etc/apt/sources.list" "$FAKE/etc/apt/sources.list.d"); OS_RELEASE="$FAKE/os-release"
      OWNER_UID="${FAKE_OWNER:-$(id -u)}"; OWNER_ROOT="$FAKE"
      STOCK_ENTRY="$FAKE/none"; VOPONO_SHA256="$GOOD_DEB_SHA"; VOPONO_BIN="${FAKE_VOPONO_BIN:-$SB/vopono}"
      fetch() { case "$1" in *mullvad-keyring.asc) cp "$FAKE/fx/key.asc" "$2" ;; *vopono*.deb) cp "$FAKE/fx/vopono.deb" "$2" ;; *) return 22 ;; esac; }
      if [[ ${FAKE_SWAP:-0} == 1 ]]; then   # something running as you swaps your copies right after each check and each root copy
          swap() { case "$1" in "$USER_TMP"/*.deb) echo evil > "$1" ;; "$USER_TMP"/key.*) cp "$T/evil.asc" "$1" ;; esac; }
          eval "orig_$(declare -f root_copy)";    root_copy()    { orig_root_copy "$@";    local r=$?; swap "$1"; return $r; }
          eval "orig_$(declare -f sha256_of)";    sha256_of()    { orig_sha256_of "$@";    local r=$?; swap "$1"; return $r; }
          eval "orig_$(declare -f canonical_key)"; canonical_key() { orig_canonical_key "$@"; local r=$?; swap "$1"; swap "$2"; return $r; }
      fi
      main "$@" ) > "$FAKE/out" 2>&1
    rc=$?
}
out_has() { grep -qF -- "$1" "$FAKE/out"; }
log_has() { grep -qF -- "$1" "$FAKE/log"; }
H() { printf '%s' "$FAKE/home/$1"; }
secure_gone() { local d; while read -r d; do [[ -z $d || ! -e $d ]] || return 1; done < "$FAKE/securedirs"; [[ -s $FAKE/securedirs ]]; }
tree_sum() { (cd "$FAKE" && find home etc keyrings db -printf '%p %m %s\n' 2>/dev/null | sort; find home etc keyrings -type f -exec sha256sum {} + 2>/dev/null | sort; cat db) | sha256sum; }

# ---------- 1. full install on a clean system ----------
newsys; inst --yes
check "clean install exits 0 (got $rc)" test "$rc" -eq 0
check "package lists refreshed first" bash -c '[[ $(grep -m1 "^apt-get" "$1") == "apt-get update" ]]' _ "$FAKE/log"
check "bootstrap: curl + CA certificates" log_has "apt-get install -y curl ca-certificates"
check "Mullvad's published key file is exactly gpg's clean copy" cmp -s "$CANON" "$MKEY"
check "installed key = gpg's clean copy of Mullvad's key" cmp -s "$CANON" "$FAKE/keyrings/mullvad-keyring.asc"
check "apt source line" grep -qx "deb \[signed-by=$FAKE/keyrings/mullvad-keyring.asc arch=amd64\] https://repository.mullvad.net/deb/stable stable main" "$D/mullvad.list"
check "only Mullvad's list refreshed after adding it, before the install" bash -c 'u=$(grep -n "^apt-get update -o Dir::Etc::sourcelist=$2 -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0\$" "$1" | cut -d: -f1); i=$(grep -n "^apt-get install -y mullvad-browser=16.0.1-1" "$1" | cut -d: -f1); [[ -n $u && -n $i && $u -lt $i ]]' _ "$FAKE/log" "$D/mullvad.list"
check "root-owned folder made" log_has "sudo mktemp -d /tmp/ghost-browser-install."
check "root-owned folder readable, not writable, by others" grep -qE '^sudo chmod 755 -- /tmp/ghost-browser-install\.' "$FAKE/log"
check "files reach root as bytes (stdin), not paths" grep -qE '^sudo install -m 644 -o root -g root -- /dev/stdin /tmp/ghost-browser-install\.[A-Za-z0-9]+/vopono_1\.0\.2_amd64\.deb$' "$FAKE/log"
check "vopono installed from the root-owned copy, unchanged" grep -qE "^/tmp/ghost-browser-install\.[A-Za-z0-9]+/vopono_1\.0\.2_amd64\.deb $GOOD_DEB_SHA\$" "$FAKE/debs"
check "vopono without its optional extras" grep -qE '^apt-get install -y --no-install-recommends /tmp/ghost-browser-install\.' "$FAKE/log"
check "other tools installed" log_has "apt-get install -y wireguard-tools nftables iptables zenity libnotify-bin iproute2 procps"
check "launcher = shipped copy, 755" bash -c 'cmp -s "$1" "$2" && [[ $(stat -c %a "$2") == 755 ]]' _ "$HERE/ghost-browser.sh" "$(H .local/bin/ghost-browser.sh)"
check "menu entry Exec" grep -qx "Exec=$FAKE/home/.local/bin/ghost-browser.sh" "$(H .local/share/applications/ghost-browser.desktop)"
check "desktop icon = menu entry, 755" bash -c 'cmp -s "$1" "$2" && [[ $(stat -c %a "$2") == 755 ]]' _ "$(H .local/share/applications/ghost-browser.desktop)" "$(H Desktop/ghost-browser.desktop)"
check "stock entry hidden" grep -qx 'Hidden=true' "$(H .local/share/applications/mullvad-browser.desktop)"
check "root-owned temp folder removed right after use" bash -c 'secure_gone() { local d; while read -r d; do [[ ! -e $d ]] || return 1; done < "$1"; [[ -s $1 ]]; }; secure_gone "$1" && grep -q "^sudo rm -rf -- /tmp/ghost-browser-install\." "$2"' _ "$FAKE/securedirs" "$FAKE/log"
check "no config written with --yes" test ! -e "$(H .config/ghost-browser/config)"
check "says done" out_has "done. Open"
if command -v desktop-file-validate >/dev/null; then
    check "menu entry passes desktop-file-validate" desktop-file-validate "$(H .local/share/applications/ghost-browser.desktop)"
fi

# ---------- 2. a same-user swap right after the root copy changes nothing that gets installed ----------
newsys; export FAKE_SWAP=1; inst --yes; unset FAKE_SWAP
# Refusing is a fine outcome; installing anything other than the checked files is not.
check "swap: the key installed (if any) is Mullvad's clean key" bash -c '! [[ -e $2 ]] || cmp -s "$1" "$2"' _ "$CANON" "$FAKE/keyrings/mullvad-keyring.asc"
check "swap: every vopono installed is the checked one" bash -c '! grep -vqE " $2\$" "$1"' _ "$FAKE/debs" "$GOOD_DEB_SHA"
newsys; echo "mullvad-browser 16.0.1-1" >> "$FAKE/db"; export FAKE_SWAP=1; inst --yes; unset FAKE_SWAP
check "swap during the vopono steps: the checked vopono is installed" bash -c '[[ $1 -eq 0 ]] && grep -qE " $3\$" "$2" && ! grep -vqE " $3\$" "$2"' _ "$rc" "$FAKE/debs" "$GOOD_DEB_SHA"
newsys; export FAKE_TAMPER=ghost-browser-install; inst --yes; unset FAKE_TAMPER
check "root's copy of the key changed: refused, nothing installed" bash -c '[[ $1 -ne 0 ]] && grep -q "copied key failed the check" "$2" && ! [[ -e $3 ]]' _ "$rc" "$FAKE/out" "$FAKE/keyrings/mullvad-keyring.asc"
newsys; echo "mullvad-browser 16.0.1-1" >> "$FAKE/db"; export FAKE_TAMPER=ghost-browser-install; inst --yes; unset FAKE_TAMPER
check "root's copy of vopono changed: refused, not installed" bash -c '[[ $1 -ne 0 ]] && grep -q "pinned SHA-256" "$2" && ! [[ -s $3 ]]' _ "$rc" "$FAKE/out" "$FAKE/debs"
newsys; export FAKE_TAMPER=mullvad.list; inst --yes; unset FAKE_TAMPER
check "apt source written wrong: caught by the read-back" bash -c '[[ $1 -ne 0 ]] && grep -q "could not write" "$2" && ! grep -q "install -y mullvad-browser" "$3"' _ "$rc" "$FAKE/out" "$FAKE/log"
newsys; echo secret > "$T/readable"; ln -sf "$T/readable" "$T/link"; mkdir -p "$T/sd"
( export PATH="$SB:$PATH"; source "$INSTALLER"; SECURE_DIR="$T/sd"; root_copy "$T/link" x ) >/dev/null 2>&1; rc=$?
check "root_copy refuses a link, copies nothing" bash -c '[[ $1 -ne 0 && ! -e $2 ]] && ! grep -q "^sudo install" "$3"' _ "$rc" "$T/sd/x" "$FAKE/log"

# ---------- 3. running again changes nothing; edited files are kept as backups ----------
newsys; inst --yes; before="$(tree_sum)"; : > "$FAKE/log"; inst --yes
check "re-run exits 0" test "$rc" -eq 0
check "re-run: nothing changed" test "$before" = "$(tree_sum)"
check "re-run: no package installs" bash -c '! grep -q "apt-get install" "$1"' _ "$FAKE/log"
check "re-run: no backups" bash -c '! find "$1" -name "*.bak-*" | grep -q .' _ "$FAKE/home"
echo "old" > "$(H .local/bin/ghost-browser.sh)"
echo "# my edit" >> "$(H .local/share/applications/ghost-browser.desktop)"
echo "# my edit" >> "$(H Desktop/ghost-browser.desktop)"
before="$(tree_sum)"; : > "$FAKE/log"; inst --dry-run
check "dry run on an edited install: nothing changed" test "$before" = "$(tree_sum)"
check "dry run: no sudo, apt, gio or desktop database" bash -c '! grep -qE "^(sudo|gio|update-desktop-database|apt-get)" "$1"' _ "$FAKE/log"
inst --yes
check "old launcher kept as .bak-*" bash -c 'grep -qx old "$1".bak-*' _ "$(H .local/bin/ghost-browser.sh)"
check "edited menu entry kept as .bak-*" bash -c 'grep -q "my edit" "$1".bak-*' _ "$(H .local/share/applications/ghost-browser.desktop)"
check "edited desktop icon kept as .bak-*" bash -c 'grep -q "my edit" "$1".bak-*' _ "$(H Desktop/ghost-browser.desktop)"
check "new launcher and entries installed" bash -c 'cmp -s "$1" "$2" && ! grep -q "my edit" "$3"' _ "$HERE/ghost-browser.sh" "$(H .local/bin/ghost-browser.sh)" "$(H .local/share/applications/ghost-browser.desktop)"

# ---------- 4. uninstall ----------
mkdir -p "$(H .config/ghost-browser)"; echo "PROVIDER=NordVPN" > "$(H .config/ghost-browser/config)"
before="$(tree_sum)"; : > "$FAKE/log"; inst --uninstall --dry-run
check "uninstall --dry-run changes nothing" test "$before" = "$(tree_sum)"
check "uninstall --dry-run: no desktop database" bash -c '! grep -q update-desktop-database "$1"' _ "$FAKE/log"
echo "bash $FAKE/home/.local/bin/ghost-browser.sh" > "$FAKE/procs"; inst --uninstall; : > "$FAKE/procs"
check "uninstall while Ghost Browser runs: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "Ghost Browser is running" "$2"' _ "$rc" "$FAKE/out"
check "uninstall while Ghost Browser runs: nothing removed" test "$before" = "$(tree_sum)"
export FAKE_ROOT=1; inst --uninstall; unset FAKE_ROOT
check "uninstall as root: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "normal user" "$2"' _ "$rc" "$FAKE/out"
echo "# my edit" >> "$(H Desktop/ghost-browser.desktop)"
inst --uninstall
check "uninstall exits 0" test "$rc" -eq 0
check "uninstall removed the launcher and menu entry" bash -c '! [[ -e $1 || -e $2 ]]' _ "$(H .local/bin/ghost-browser.sh)" "$(H .local/share/applications/ghost-browser.desktop)"
check "uninstall removed the stock override" test ! -e "$(H .local/share/applications/mullvad-browser.desktop)"
check "uninstall kept the edited desktop icon" test -e "$(H Desktop/ghost-browser.desktop)"
check "uninstall kept config and backups" bash -c '[[ -e $1 ]] && ls "$2".bak-* >/dev/null 2>&1' _ "$(H .config/ghost-browser/config)" "$(H .local/bin/ghost-browser.sh)"
newsys; inst --yes; echo "# mine" >> "$(H .local/bin/ghost-browser.sh)"; inst --uninstall
check "uninstall leaves an edited launcher" bash -c '[[ -e $1 ]] && grep -q "not this version" "$2"' _ "$(H .local/bin/ghost-browser.sh)" "$FAKE/out"

# ---------- 5. dry run on a clean system ----------
newsys; before="$(tree_sum)"; inst --dry-run
check "dry run exits 0 (got $rc)" test "$rc" -eq 0
check "dry run: nothing changed" test "$before" = "$(tree_sum)"
check "dry run: no sudo, no apt" bash -c '! grep -qE "^(sudo|apt-get)" "$1"' _ "$FAKE/log"
check "dry run names the vopono checksum" out_has "check SHA-256"

# ---------- 6. the Mullvad key download ----------
newsys; cp "$T/evil.asc" "$FAKE/fx/key.asc"; inst --yes
check "wrong key: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "failed the check" "$2"' _ "$rc" "$FAKE/out"
check "wrong key: no key, no source, no Mullvad install" bash -c '! [[ -e $1 || -e $2 ]] && ! grep -q "install -y mullvad-browser" "$3"' _ "$FAKE/keyrings/mullvad-keyring.asc" "$D/mullvad.list" "$FAKE/log"
newsys; cp "$T/hidden.asc" "$FAKE/fx/key.asc"; inst --yes
check "key + hidden non-PGP block: only the clean key is installed" bash -c '[[ $1 -eq 0 ]] && cmp -s "$2" "$3"' _ "$rc" "$CANON" "$FAKE/keyrings/mullvad-keyring.asc"
newsys; cp "$T/crc.asc" "$FAKE/fx/key.asc"; inst --yes
check "key + attacker key after the checksum line: only the clean key is installed" bash -c '[[ $1 -eq 0 ]] && cmp -s "$2" "$3"' _ "$rc" "$CANON" "$FAKE/keyrings/mullvad-keyring.asc"
newsys; cp "$T/two.asc" "$FAKE/fx/key.asc"; inst --yes
check "key + a second public key: refused" bash -c '[[ $1 -ne 0 ]] && ! [[ -e $2 ]]' _ "$rc" "$FAKE/keyrings/mullvad-keyring.asc"
newsys; cp "$T/secret.asc" "$FAKE/fx/key.asc"; inst --yes
check "key + a secret key block: refused" bash -c '[[ $1 -ne 0 ]] && ! [[ -e $2 ]]' _ "$rc" "$FAKE/keyrings/mullvad-keyring.asc"

# ---------- 7. a key file that is already there ----------
newsys; cp "$MKEY" "$FAKE/keyrings/mullvad-keyring.asc"; rm "$FAKE/fx/key.asc"; inst --yes
check "existing right key: reused, no download" bash -c '[[ $1 -eq 0 ]] && grep -q "exactly the published key" "$2"' _ "$rc" "$FAKE/out"
for trick in hidden crc evil; do
    newsys; cp "$T/$trick.asc" "$FAKE/keyrings/mullvad-keyring.asc"; inst --yes
    check "existing key file ($trick): replaced by the checked key, old one kept as .bak" bash -c '[[ $1 -eq 0 ]] && cmp -s "$2" "$3" && cmp -s "$4" "$5"/mullvad-keyring.asc.*.bak' _ "$rc" "$CANON" "$FAKE/keyrings/mullvad-keyring.asc" "$T/$trick.asc" "$FAKE/keyrings"
done

# ---------- 8. a Mullvad package source that is already there: only the installer's own exact line is used ----------
src_refused() {   # src_refused NAME: refused before any sudo
    check "$1: refused before sudo" bash -c '[[ $1 -ne 0 ]] && grep -qE "did not write|is not byte for byte|is a link|reported a problem reading|key file|not owned by root" "$2" && ! grep -q "^sudo" "$3"' _ "$rc" "$FAKE/out" "$FAKE/log"
}
good_source() { cp "$MKEY" "$K"; printf '%s\n' "${1:-$GOODLINE}" > "$D/mullvad.list"; }
newsys; good_source; rm "$FAKE/fx/key.asc"; before="$(sha256sum "$K" "$D/mullvad.list")"; inst --yes
check "the installer's own line + exact key: used, nothing rewritten" bash -c '[[ $1 -eq 0 ]] && [[ $2 == "$(sha256sum "$3" "$4")" ]] && grep -q "install -y mullvad-browser=" "$5" && grep -q "used as it is" "$6"' _ "$rc" "$before" "$K" "$D/mullvad.list" "$FAKE/log" "$FAKE/out"
newsys; good_source "${GOODLINE/ stable main/ noble main}"; rm "$FAKE/fx/key.asc"; inst --yes
check "same line with a release name (as Mullvad's guide writes it): used" bash -c '[[ $1 -eq 0 ]] && grep -q "used as it is" "$2"' _ "$rc" "$FAKE/out"
VT=$'\v'; AT='@'   # user@host addresses are built from AT
for bad in "deb [trusted=yes] http://repository.mullvad.net/deb/stable stable main" \
           "deb [signed-by=K arch=amd64 trusted=yes] https://repository.mullvad.net/deb/stable stable main" \
           "deb [signed-by=K${VT}trusted=yes arch=amd64] https://repository.mullvad.net/deb/stable stable main" \
           "deb [signed-by=K,/tmp/evil.gpg arch=amd64] https://repository.mullvad.net/deb/stable stable main" \
           "deb [signed-by=/other/key.asc arch=amd64] https://repository.mullvad.net/deb/stable stable main" \
           "deb [signed-by=K arch=amd64] https://x${AT}repository.mullvad.net/deb/stable stable main" \
           "deb [signed-by=K arch=amd64] https://Repository.Mullvad.NET/deb/stable stable main" \
           "deb [signed-by=K arch=amd64] https://repository.mullvad.net/deb/beta beta main" \
           "deb [signed-by=K arch=amd64] http://repository.mullvad.net/deb/stable stable main" \
           "deb [signed-by=K] https://repository.mullvad.net/deb/stable stable main"; do
    newsys; good_source "${bad//K/$K}"; inst --yes; src_refused "mullvad.list '$(printf '%s' "${bad:0:58}" | tr '\v' '?')'"
done
newsys; good_source; echo "$GOODLINE" >> "$D/mullvad.list"; inst --yes
check "the right line twice: refused" bash -c '[[ $1 -ne 0 ]] && ! grep -q "^sudo" "$2"' _ "$rc" "$FAKE/log"
newsys; cp "$MKEY" "$K"; echo "$GOODLINE" > "$D/mine.list"; inst --yes; src_refused "a correct line in another file"
check "the refusal names the file and says how to switch it off" bash -c 'grep -q "mine.list" "$1" && grep -q "ends in .disabled" "$1"' _ "$FAKE/out"
newsys; good_source; printf '%s' "$GOODLINE" > "$D/mullvad.list"; printf '\ndeb [trusted=yes] http://203.0.113.9/deb stable main' >> "$D/mullvad.list"; inst --yes; src_refused "the right line plus a second line with no line ending"
newsys; good_source "$GOODLINE extra"; inst --yes; src_refused "the right line plus an extra component"
newsys; good_source "$GOODLINE # note"; inst --yes; src_refused "the right line plus a trailing comment"
newsys; good_source; mv "$D/mullvad.list" "$FAKE/real.list"; ln -s "$FAKE/real.list" "$D/mullvad.list"; inst --yes; src_refused "mullvad.list is a link to an identical file"
newsys; good_source; echo "$GOODLINE" > "$D/zz.list"; inst --yes; src_refused "the same line again in a second file (apt warns: configured multiple times)"
newsys; good_source; echo "deb [trusted=yes] http://203.0.113.9/deb stable main" > "$D/hidden.list"; chmod 000 "$D/hidden.list"; inst --yes; chmod 644 "$D/hidden.list"; src_refused "a source file your user cannot read (apt only warns)"
newsys; echo "deb [trusted=yes] http://203.0.113.9/deb stable main" > "$D/hidden.list"; chmod 000 "$D/hidden.list"; inst --yes; chmod 644 "$D/hidden.list"; src_refused "no Mullvad source, but an unreadable source file"
newsys; echo "mullvad-browser 16.0.1-1" >> "$FAKE/db"; printf 'Types: deb\nURIs: https://repository.mullvad.net/deb/stable\nSuites: stable\nComponents: main\nSigned-By: /x\n' > "$D/mine.sources"; before="$(sha256sum "$D/mine.sources")"; inst --yes
check "Mullvad Browser already installed: your own Mullvad source is left alone, not refused" bash -c '[[ $1 -eq 0 ]] && [[ $2 == "$(sha256sum "$3")" ]]' _ "$rc" "$before" "$D/mine.sources"
newsys; cp "$MKEY" "$K"; printf 'Types: deb\nURIs: https://repository.mullvad.net/deb/stable\nSuites: stable\nComponents: main\nSigned-By: %s\n \nTrusted: yes\n' "$K" > "$D/m.sources"; inst --yes; src_refused "any .sources entry (here with a hidden Trusted: yes)"
newsys; good_source; echo "deb [signed-by=$K arch=amd64] https://user${AT}REPOSITORY.mullvad.net/deb/stable stable main" > "$D/zz.list"; inst --yes; src_refused "a second Mullvad entry with user@ and capitals"
for trick in hidden crc evil; do
    newsys; good_source; cp "$T/$trick.asc" "$K"; inst --yes; src_refused "the right line but a doctored key file ($trick)"
done
newsys; good_source; gpg --homedir "$CG" --batch --export A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF > "$K"; inst --yes; src_refused "the right line but a binary key file"
newsys; good_source; chmod 664 "$D/mullvad.list"; inst --yes; src_refused "source file writable by its group"
newsys; good_source; chmod 666 "$K"; inst --yes; src_refused "key file writable by anyone"
newsys; good_source; chmod 777 "$FAKE/keyrings"; inst --yes; src_refused "key folder writable by anyone"
newsys; good_source; export FAKE_OWNER=0; inst --yes; unset FAKE_OWNER; src_refused "source and key not owned by root"
newsys
printf 'deb [signed-by=/a] https://repository.mullvad.net/deb/stable stable main\ndeb [signed-by=/b] https://repository.mullvad.net/deb/stable stable main\n' > "$D/two.list"; inst --yes
src_refused "sources apt cannot read"
newsys
echo "# deb [signed-by=/x] https://repository.mullvad.net/deb/stable stable main" > "$D/mullvad.list"
echo "deb https://repository.mullvad.net/deb/stable stable main" > "$D/mullvad.list.save"
printf 'Types: deb\nURIs: https://repository.mullvad.net/deb/stable\nSuites: stable\nComponents: main\nEnabled: no\n' > "$D/off.sources"; inst --yes
check "commented / .save / disabled entries: ignored, set up fresh" bash -c '[[ $1 -eq 0 ]] && cmp -s "$2" "$3" && grep -q "^deb \[signed-by=" "$4"' _ "$rc" "$CANON" "$K" "$D/mullvad.list"
check "old mullvad.list kept as .bak" bash -c 'ls "$1"/mullvad.list.*.bak >/dev/null 2>&1' _ "$D"
newsys; gpg --homedir "$CG" --batch --export A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF > "$K"; inst --yes
check "no source yet, binary key at the key path: replaced by the armored checked key" bash -c '[[ $1 -eq 0 ]] && cmp -s "$2" "$3" && ls "$3".*.bak >/dev/null' _ "$rc" "$CANON" "$K"
newsys; printf ' mullvad-browser |   16.0.1-1 | https://repository.mullvad.net/deb/stable stable/main amd64 Packages\n mullvad-browser |   16.0.1-1 | https://mirror.example/deb stable/main amd64 Packages\n' > "$FAKE/madison"; inst --yes
check "mullvad-browser also offered elsewhere: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "offered by a source that is not Mullvad" "$2" && ! grep -q "install -y mullvad-browser" "$3"' _ "$rc" "$FAKE/out" "$FAKE/log"
newsys; printf ' mullvad-browser |   16.0.1-1 | https://evil.example/repository.mullvad.net/deb/stable stable/main amd64 Packages\n' > "$FAKE/madison"; inst --yes
check "a look-alike address containing Mullvad's: refused" bash -c '[[ $1 -ne 0 ]] && ! grep -q "install -y mullvad-browser" "$2"' _ "$rc" "$FAKE/log"
for site in "http://repository.mullvad.net/deb/stable stable/main" "https://repository.mullvad.net/deb/beta beta/main" "https://repository.mullvad.net/deb/stable-x stable/main" "https://repositoryxmullvad.net/deb/stable stable/main" "https://evil.example/https://repository.mullvad.net/deb/stable stable/main"; do
    newsys; printf ' mullvad-browser |   16.0.1-1 | %s amd64 Packages\n' "$site" > "$FAKE/madison"; inst --yes
    check "package offered from '$site': refused" bash -c '[[ $1 -ne 0 ]] && ! grep -q "install -y mullvad-browser" "$2"' _ "$rc" "$FAKE/log"
done
newsys; inst --yes
check "the 'Mullvad only' check is asked through sudo (root's view of the sources)" bash -c 'grep -q "^sudo env LC_ALL=C apt-cache policy mullvad-browser" "$1" && grep -q "^sudo env LC_ALL=C apt-cache madison mullvad-browser" "$1"' _ "$FAKE/log"
check "the key is installed from root's checked copy" grep -qE "^sudo install -m 644 -o root -g root -- /tmp/ghost-browser-install\.[A-Za-z0-9]+/mullvad-keyring\.asc $K\$" "$FAKE/log"
newsys; printf ' mullvad-browser |   15.0 | https://repository.mullvad.net/deb/stable stable/main amd64 Packages\n' > "$FAKE/madison"; inst --yes
check "candidate version not offered by Mullvad's repository: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "not offered by Mullvad" "$2" && ! grep -q "install -y mullvad-browser" "$3"' _ "$rc" "$FAKE/out" "$FAKE/log"
newsys; printf ' mullvad-browser |   99.0 | https://mirror.example/deb stable/main amd64 Packages\n' > "$FAKE/madison"; export FAKE_CANDIDATE=99.0; inst --yes; unset FAKE_CANDIDATE
check "mullvad-browser only from elsewhere: refused" bash -c '[[ $1 -ne 0 ]] && ! grep -q "install -y mullvad-browser" "$2"' _ "$rc" "$FAKE/log"
newsys; export FAKE_UPDATE_FAIL=1; inst --yes; unset FAKE_UPDATE_FAIL
check "Mullvad's repository cannot be read: stops, nothing installed from it" bash -c '[[ $1 -ne 0 ]] && grep -q "could not read Mullvad" "$2" && ! grep -q "install -y mullvad-browser" "$3"' _ "$rc" "$FAKE/out" "$FAKE/log"
newsys; echo "vopono 0.10.22-1" >> "$FAKE/db"; inst --yes
check "kept an older vopono: the root-owned temp folder is still removed at once" bash -c '[[ $1 -eq 0 ]] && grep -q "^sudo rm -rf -- /tmp/ghost-browser-install\." "$2" && while read -r d; do [[ ! -e $d ]] || exit 1; done < "$3"' _ "$rc" "$FAKE/log" "$FAKE/securedirs"
newsys; echo "mullvad-browser 16.0.1-1" >> "$FAKE/db"; inst --yes
check "Mullvad Browser installed: repo untouched" bash -c '! [[ -e $1 || -e $2 ]] && ! grep -q "install -y mullvad-browser" "$3"' _ "$FAKE/keyrings/mullvad-keyring.asc" "$D/mullvad.list" "$FAKE/log"
newsys; echo "mullvad-browser 16.0.1-1 config-files" >> "$FAKE/db"; inst --yes
check "removed-but-configured Mullvad Browser counts as missing" log_has "apt-get install -y mullvad-browser="

# ---------- 9. vopono checksum, version, PATH ----------
newsys; echo "mullvad-browser 16.0.1-1" >> "$FAKE/db"; echo tampered >> "$FAKE/fx/vopono.deb"; inst --yes
check "tampered vopono: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "does not match the pinned SHA-256" "$2"' _ "$rc" "$FAKE/out"
check "tampered vopono: not installed" test ! -s "$FAKE/debs"
newsys; printf 'mullvad-browser 16.0.1-1\nvopono 0.10.22-1\n' >> "$FAKE/db"; inst --yes
check "other vopono + --yes: kept, warned" bash -c '[[ $1 -eq 0 ]] && grep -q "tested with 1.0.2 only" "$2" && ! [[ -s $3 ]]' _ "$rc" "$FAKE/out" "$FAKE/debs"
newsys; printf 'mullvad-browser 16.0.1-1\nvopono 1.0.2-1\n' >> "$FAKE/db"; inst --yes
check "vopono 1.0.2 installed: no download" bash -c '! [[ -s $1 ]] && grep -q "the tested version" "$2"' _ "$FAKE/debs" "$FAKE/out"
newsys; printf 'mullvad-browser 16.0.1-1\nvopono 1.0.2-1\n' >> "$FAKE/db"; export FAKE_VOPONO_BIN=/usr/bin/vopono; inst --yes; unset FAKE_VOPONO_BIN
check "another vopono first on PATH: warned" out_has "'vopono' on your PATH is $SB/vopono"

# ---------- 10. refusals ----------
newsys; printf 'ID=fedora\n' > "$FAKE/os-release"; inst --yes
check "Fedora: refused before any change" bash -c '[[ $1 -ne 0 ]] && grep -q "supports Debian, Ubuntu, Linux Mint" "$2" && ! [[ -s $3 ]]' _ "$rc" "$FAKE/out" "$FAKE/log"
newsys; export FAKE_ARCH=arm64; inst --yes; unset FAKE_ARCH
check "arm64: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "amd64) only" "$2"' _ "$rc" "$FAKE/out"
newsys; export FAKE_ROOT=1; inst --yes; unset FAKE_ROOT
check "as root: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "normal user" "$2"' _ "$rc" "$FAKE/out"
newsys; echo "bash $FAKE/home/.local/bin/ghost-browser.sh" > "$FAKE/procs"; inst --yes
check "Ghost Browser running (menu launch): refused before any change" bash -c '[[ $1 -ne 0 ]] && grep -q "Ghost Browser is running" "$2" && ! [[ -s $3 ]]' _ "$rc" "$FAKE/out" "$FAKE/log"
newsys; echo "/usr/bin/bash $FAKE/home/.local/bin/ghost-browser.sh --check" > "$FAKE/procs"; inst --yes
check "Ghost Browser running (--check): refused" bash -c '[[ $1 -ne 0 ]] && grep -q "Ghost Browser is running" "$2"' _ "$rc" "$FAKE/out"
newsys; echo "vim $FAKE/home/.local/bin/ghost-browser.sh" > "$FAKE/procs"; inst --yes
check "launcher open in an editor: not counted as running" test "$rc" -eq 0
newsys; echo "vo_gb12345678 (id: 0)" > "$FAKE/netns"; inst --yes
check "a Ghost Browser namespace up: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "Ghost Browser is running" "$2"' _ "$rc" "$FAKE/out"
newsys; inst
check "no terminal, no --yes: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "run this in a terminal" "$2"' _ "$rc" "$FAKE/out"
newsys; export FAKE_SUDO_FAIL=1; inst --yes; unset FAKE_SUDO_FAIL
# This sandbox may itself have no_new_privs set, which picks the other message.
check "sudo fails: stops before any change" bash -c '[[ $1 -ne 0 ]] && grep -qE "sudo failed|sudo is blocked" "$2" && ! grep -q apt-get "$3"' _ "$rc" "$FAKE/out" "$FAKE/log"
if command -v setpriv >/dev/null; then
    newsys; export FAKE_SUDO_FAIL=1
    ( export PATH="$SB:$PATH"; setpriv --no-new-privs bash -c "source '$INSTALLER'; DRY=0; check_sudo" ) > "$FAKE/out" 2>&1; rc=$?; unset FAKE_SUDO_FAIL
    check "no_new_privs: says to use a normal terminal" bash -c '[[ $1 -ne 0 ]] && grep -q "no new privileges" "$2"' _ "$rc" "$FAKE/out"
fi
mkdir -p "$T/nosudo"; for c in id awk; do ln -sf "$(command -v $c)" "$T/nosudo/$c"; done
( source "$INSTALLER"; PATH="$T/nosudo"; DRY=0; check_sudo ) > "$T/nosudo.out" 2>&1; rc=$?
check "sudo missing: says how to get it" bash -c '[[ $1 -ne 0 ]] && grep -q "sudo is not installed" "$2"' _ "$rc" "$T/nosudo.out"
newsys; mv "$FAKE/home" "$FAKE/my home"; ( export HOME="$FAKE/my home" PATH="$SB:$PATH"; source "$INSTALLER"; OS_RELEASE="$FAKE/os-release"; DRY=1; check_system ) > "$FAKE/out" 2>&1; rc=$?
check "home path with a space: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "has a space" "$2"' _ "$rc" "$FAKE/out"
newsys; inst --bogus
check "unknown option: refused" bash -c '[[ $1 -ne 0 ]] && grep -q "unknown option" "$2"' _ "$rc" "$FAKE/out"

# ---------- 11. pieces ----------
( source "$INSTALLER"
  [[ $(desktop_exec /opt/a/.local/bin/x.sh) == /opt/a/.local/bin/x.sh ]] || echo "plain path"
  [[ $(desktop_exec '/opt/a b/x.sh') == '"/opt/a b/x.sh"' ]] || echo "space"
  [[ $(desktop_exec '/h/a$b"c%d') == '"/h/a\\$b\\"c%%d"' ]] || echo "dollar/quote/percent"
) > "$T/pieces"
check "desktop_exec quoting $(tr '\n' ';' < "$T/pieces")" test ! -s "$T/pieces"

newsys; mkdir -p "$(H .config/ghost-browser)"; C="$(H .config/ghost-browser/config)"
printf 'PROVIDER=\n#CONFIG_DIR=~/vpn-configs\nSERVERS=\n# with PROVIDER: keep\n' > "$C"
( source "$INSTALLER"; CONFIG_FILE="$C"; DRY=0
  set_config PROVIDER NordVPN; set_config SERVERS "us ca"; set_config CONFIG_DIR "/x y/z"
  for v in 'us#x' 'a\b' $'a\nPROVIDER=evil' ' lead' 'trail ' '"quoted"' "'quoted'"; do
      ( set_config SERVERS "$v" ) 2>/dev/null && echo "leaked: $v" >> "$C"
  done ) >/dev/null 2>&1
check "set_config result (and every bad value refused)" test "$(cat "$C")" = $'PROVIDER=NordVPN\nCONFIG_DIR=/x y/z\nSERVERS=us ca\n# with PROVIDER: keep'
check "set_config: config is private (600)" test "$(stat -c %a "$C")" = 600

( source "$INSTALLER"
  CONFIG_FILE="$T/lo"
  printf 'PROVIDER=NordVPN\nSERVERS=us\n' > "$CONFIG_FILE"; load_ok || echo "provider+servers"
  printf 'PROVIDER=NordVPN\nSERVERS=\n' > "$CONFIG_FILE"; load_ok && echo "provider without servers"
  printf '  CONFIG_DIR = /x\n' > "$CONFIG_FILE"; load_ok || echo "spaced CONFIG_DIR"
  printf '#CONFIG_DIR=/x\nPROVIDER=\n' > "$CONFIG_FILE"; load_ok && echo "commented"
  printf 'PROVIDER= # NordVPN\nSERVERS=us\n' > "$CONFIG_FILE"; load_ok && echo "comment as value"
  printf 'PROVIDER=""\nSERVERS=""\n' > "$CONFIG_FILE"; load_ok && echo "empty quotes"
  printf "CONFIG_DIR=''\n" > "$CONFIG_FILE"; load_ok && echo "empty single quotes"
  printf 'PROVIDER="NordVPN"\nSERVERS= us \n' > "$CONFIG_FILE"; load_ok || echo "quoted provider"
  printf 'PROVIDER=\r\nSERVERS=\r\n' > "$CONFIG_FILE"; load_ok && echo "CRLF blanks"
) > "$T/lo.out"
check "load_ok cases $(tr '\n' ';' < "$T/lo.out")" test ! -s "$T/lo.out"

if command -v python3 >/dev/null; then
    ( cd "$T" && echo hi > served && exec python3 -u -m http.server --bind 127.0.0.1 0 ) > "$T/http.log" 2>&1 &
    hp=$!; port=""
    for _ in $(seq 50); do port="$(grep -oE 'port [0-9]+' "$T/http.log" | grep -oE '[0-9]+' | head -1)"; [[ -n $port ]] && break; sleep 0.1; done
    if [[ -n $port ]]; then
        curl -fsS -o "$T/plain" "http://127.0.0.1:$port/served" 2>/dev/null
        ( source "$INSTALLER"; fetch "http://127.0.0.1:$port/served" "$T/viafetch" ) 2>/dev/null
        check "downloads refuse plain http (plain curl would get it)" bash -c '[[ -s $1 && ! -s $2 ]]' _ "$T/plain" "$T/viafetch"
    else bad "no local http server for the fetch test"; fi
    kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
fi
printf '#!/bin/sh\necho "$@" > "%s/curl.args"\n' "$T" > "$SB/curl"; chmod 755 "$SB/curl"
( PATH="$SB:$PATH"; source "$INSTALLER"; fetch https://example.invalid/x "$T/x" )
check "downloads: https only, also after redirects, TLS 1.2+" grep -q -- "--proto =https --proto-redir =https --tlsv1.2" "$T/curl.args"
rm -f "$SB/curl"

# ---------- 12. guided VPN setup ----------
setup() {   # setup INPUT [existing-config-text]: answers on stdin
    newsys; printf 'mullvad-browser 16.0.1-1\nvopono 1.0.2-1\n' >> "$FAKE/db"
    C="$(H .config/ghost-browser/config)"
    if [[ -n ${2:-} ]]; then mkdir -p "$(dirname "$C")"; printf '%s\n' "$2" > "$C"; chmod 644 "$C"; fi
    printf '%b' "$1" > "$FAKE/in"
    ( umask 002; export HOME="$FAKE/home" PATH="$SB:$PATH"; source "$INSTALLER"
      DRY=0; ASSUME_YES=0; USER_TMP="$(mktemp -d)"; VOPONO_BIN="$SB/vopono"; ask() { [[ $2 == y ]]; }
      mkdir -p "$BIN_DIR"; install -m 755 "$SRC_LAUNCHER" "$LAUNCHER"; setup_vpn; echo "FAILED=$FAILED" ) < "$FAKE/in" > "$FAKE/out" 2>&1
    rc=$?
}
mode600() { [[ $(stat -c %a "$C") == 600 ]]; }
setup '1\nnordvpn\nus ca\n'
check "setup 1: PROVIDER + SERVERS" bash -c 'grep -qx PROVIDER=NordVPN "$1" && grep -qx "SERVERS=us ca" "$1"' _ "$C"
check "setup 1: ran vopono sync" log_has "vopono sync NordVPN --protocol Wireguard"
check "setup 1: config 600" mode600
setup '1\nprivateinternetaccess\n'
check "setup 1: PIA not offered (its synced files do not work)" bash -c 'grep -q "is not in the list" "$1" && grep -qx "PROVIDER=" "$2"' _ "$FAKE/out" "$C"
check "setup 1 refused: config 600" mode600
setup '1\nnordvpn\nus; rm -rf ~\n'
check "setup 1, bad SERVERS: nothing written" bash -c 'grep -qx "SERVERS=" "$1" && grep -qx "PROVIDER=" "$1"' _ "$C"
export FAKE_SYNC_RC=1; setup '1\nnordvpn\nus\n'; unset FAKE_SYNC_RC
check "setup 1, sync fails: PROVIDER not set" bash -c 'grep -qx "PROVIDER=" "$1" && grep -q "vopono sync failed" "$2"' _ "$C" "$FAKE/out"
check "setup 1, sync fails: config 600" mode600
mkdir -p "$T/my wg"; chmod 755 "$T/my wg"
setup "2\n$T/my wg\n"
check "setup 2: CONFIG_DIR (absolute, with a space)" grep -qx "CONFIG_DIR=$T/my wg" "$C"
check "setup 2: folder made private" test "$(stat -c %a "$T/my wg")" = 700
check "setup 2: a failed config check is reported" grep -q "FAILED=1" "$FAKE/out"
setup "2\n$T/my wg\n" $'PROVIDER=NordVPN\nSERVERS=\nCONFIG_DIR='
check "setup 2 on a PROVIDER config: PROVIDER cleared" bash -c 'grep -qx "PROVIDER=" "$1" && grep -qx "CONFIG_DIR=$2" "$1"' _ "$C" "$T/my wg"
setup '3\n'
check "setup 3: starter config only, 600" bash -c 'grep -qx "PROVIDER=" "$1" && grep -q "skipped" "$2" && [[ $(stat -c %a "$1") == 600 ]]' _ "$C" "$FAKE/out"
setup '1\nmullvad\nse\n' $'# mine\nPROVIDER=\nSERVERS=\nHOST_IFACE=eth0'
check "config without a VPN: filled in, rest kept" test "$(cat "$C")" = $'# mine\nPROVIDER=Mullvad\nSERVERS=se\nHOST_IFACE=eth0'
setup '' $'PROVIDER=Mullvad\nSERVERS=se'
check "config with a VPN: left as it is" bash -c '[[ $(cat "$1") == "$3" ]] && grep -q "left as it is" "$2"' _ "$C" "$FAKE/out" $'PROVIDER=Mullvad\nSERVERS=se'
( export GHOST_BROWSER_CONFIG="$T/elsewhere.conf"; source "$INSTALLER"; echo "$CONFIG_FILE" ) > "$T/cf"
check "GHOST_BROWSER_CONFIG is honoured, like the launcher" grep -qx "$T/elsewhere.conf" "$T/cf"

# ---------- 13. a failed check ends in "NOT ready" and an error exit ----------
( source "$INSTALLER"; FAILED=1; finish ) > "$T/fin" 2>&1; rc=$?
check "failed check: NOT ready, exit 1" bash -c '[[ $1 -eq 1 ]] && grep -q "NOT ready" "$2" && ! grep -q "done. Open" "$2"' _ "$rc" "$T/fin"
printf '#!/bin/sh\nexit 1\n' > "$T/false-launcher"; chmod 755 "$T/false-launcher"
( source "$INSTALLER"; LAUNCHER="$T/false-launcher"; ask() { return 0; }; load_ok() { return 0; }; final_checks; echo "FAILED=$FAILED" ) > "$T/fc" 2>&1
check "failed self-test sets the failure flag" grep -q "FAILED=1" "$T/fc"
printf '#!/bin/sh\necho "$1" >> "%s/calls"\n[ "$1" = --check ] && exit 1\nexit 0\n' "$T" > "$T/check-fails"; chmod 755 "$T/check-fails"
( source "$INSTALLER"; LAUNCHER="$T/check-fails"; ask() { return 0; }; load_ok() { return 0; }; final_checks; echo "FAILED=$FAILED" ) > "$T/fc2" 2>&1
check "self-test and exit-IP check both run; a failed --check sets the flag" bash -c 'grep -q "FAILED=1" "$1" && [[ $(tr "\n" " " < "$2") == "--selftest --check " ]]' _ "$T/fc2" "$T/calls"
( export HOME="$T/novpn"; mkdir -p "$HOME"; source "$INSTALLER"; SETUP=1; ASSUME_YES=0; DRY=0; finish ) > "$T/fin2" 2>&1; rc=$?
check "setup left no VPN: NOT ready, exit 1" bash -c '[[ $1 -eq 1 ]] && grep -q "no VPN is set" "$2"' _ "$rc" "$T/fin2"

check "every root-owned temp folder made in these tests is gone" bash -c 'for f in "$1"/sys.*/securedirs; do while read -r d; do [[ -z $d || ! -e $d ]] || exit 1; done < "$f"; done' _ "$T"
check "no gpg agents left from the installer" bash -c '! pgrep -f "gpg-agent.*--homedir $1/tmp" >/dev/null' _ "$T"
echo "$pass passed, $failn failed"
(( failn == 0 ))
