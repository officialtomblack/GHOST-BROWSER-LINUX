# Proof: what was tested, how, and what wasn't

This page is the long version of the README's "Proof, not promises". Everything here can be re-run.

## 1. What was run on a real VPN

Setup: Linux Mint 22, NordVPN over WireGuard (NordLynx also running system-wide), vopono 1.0.2, Mullvad Browser 16.0.1. Date: 2026-11-15. IP addresses below are replaced with example ones; nothing else is changed.

| Check | Result |
|---|---|
| Real launch from a terminal | Browser opened in its own namespace through a NordVPN US server |
| Download of a 1 MB test file | Landed in the RAM run folder (`/run/user/<uid>/ghost-browser.XXXXXXXX/home/.mullvad-browser/Downloads/`, tmpfs). The browser's temp folder was in the same RAM folder. Nothing new in `/tmp` except the empty update-lock file (see "Known traces") |
| Kill-switch cut (below) | `RESULT: PASS` |
| `--check` | `PASS exit`: the namespace's exit address was the VPN's, not the host's |
| After closing | 0 namespaces, 0 leftover network links, no browser or vopono process, RAM folder gone |
| Host VPN before vs after | Identical: a snapshot of the system VPN's status and settings, both WireGuard links, all routing rules and both tunnels' routes had the same SHA-256 before and after |

### The kill-switch cut, full output

```
$ sudo bash killswitch-test.sh
== namespace vo_gb7e251d, tunnel interface vo_gb7e251d
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
vo_gb7e251d      UNKNOWN        <POINTOPOINT,NOARP,UP,LOWER_UP>
vo_gb7e251d_s@if29 UP           56:f2:90:a5:c2:b3 <BROADCAST,MULTICAST,UP,LOWER_UP>
== ip rule
0:      from all lookup local
32764:  from all lookup main suppress_prefixlength 0
32765:  not from all fwmark 0xca6c lookup 51820
32766:  from all lookup main
32767:  from all lookup default
== routes (all tables)
default dev vo_gb7e251d table 51820 scope link
default via 10.200.1.1 dev vo_gb7e251d_s
10.200.1.0/24 dev vo_gb7e251d_s proto kernel scope link src 10.200.1.2
203.0.113.46 via 10.200.1.1 dev vo_gb7e251d_s
== firewall inside the namespace
table ip filter {
    chain OUTPUT {
        type filter hook output priority filter; policy accept;
        ip daddr 103.86.99.100 oifname "vo_gb7e251d" tcp dport 53 counter packets 0 bytes 0 accept
        ip daddr 103.86.99.100 oifname "vo_gb7e251d" udp dport 53 counter packets 0 bytes 0 accept
        ip daddr 103.86.96.100 oifname "vo_gb7e251d" tcp dport 53 counter packets 0 bytes 0 accept
        ip daddr 103.86.96.100 oifname "vo_gb7e251d" udp dport 53 counter packets 5 bytes 321 accept
        ip daddr 103.86.99.100 oifname "vo_gb7e251d" counter packets 0 bytes 0 accept
        ip daddr 103.86.96.100 oifname "vo_gb7e251d" counter packets 0 bytes 0 accept
        oifname != "vo_gb7e251d" meta mark != 0x0000ca6c fib daddr type != local counter packets 0 bytes 0 reject
    }
}
table ip6 filter {
    chain INPUT   { type filter hook input priority filter; policy drop;   counter packets 0 bytes 0 drop }
    chain FORWARD { type filter hook forward priority filter; policy drop; counter packets 0 bytes 0 drop }
    chain OUTPUT  { type filter hook output priority filter; policy drop;  counter packets 9 bytes 580 drop }
}
== BEFORE the cut
203.0.113.59
direct 1.1.1.1: REACHED
== tunnel vo_gb7e251d is now DOWN
vo_gb7e251d      DOWN           <POINTOPOINT,NOARP>
default via 10.200.1.1 dev vo_gb7e251d_s
10.200.1.0/24 dev vo_gb7e251d_s proto kernel scope link src 10.200.1.2
203.0.113.46 via 10.200.1.1 dev vo_gb7e251d_s
== AFTER the cut
curl: (6) Could not resolve host: am.i.mullvad.net
direct 1.1.1.1: no answer
RESULT: PASS - nothing gets out with the tunnel down.
```

How to read it: after the cut, a default route to the host **still exists** (`default via 10.200.1.1`). The traffic is stopped by the `reject` rule: anything leaving by a device other than the tunnel, without the tunnel's own mark (`0xca6c`), is refused. That firewall is vopono's. Ghost Browser's part is steps 13 to 15 in the README: confirming, from inside, that this layout is really there before the browser starts.

## 1b. The installer on clean machines

Date: 2026-11-17. Two throwaway QEMU/KVM virtual machines from the official cloud images (checksums verified): **Debian 12** (apt 2.6.2, starts without gpg) and **Ubuntu 24.04** (apt 2.8.3). A normal user with sudo, `bash install.sh --yes`.

| Check | Debian 12 | Ubuntu 24.04 |
|---|---|---|
| Install finishes, exit code 0 | yes | yes |
| Installed key is byte-identical to Mullvad's published key; key and source root-owned, mode 644 | yes | yes |
| `mullvad-browser` comes from `https://repository.mullvad.net/deb/stable` | yes | yes |
| vopono 1.0.2 installed; `redsocks` and `openvpn` (its optional extras) **not** installed | yes | yes |
| No root-owned temp folder left in `/tmp` | yes | yes |
| Second run changes nothing | yes | yes |
| Browser removed, installer run again: the existing source is recognised as the installer's own and reused | yes | yes |
| `ghost-browser.sh --selftest`: `RESULT: plumbing PASS \| dead-tunnel PASS`, nothing left behind | yes | yes |
| `tests.sh` | 108 passed | 108 passed after `sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0`; 72 passed + 4 groups skipped without it |
| `install-tests.sh` | 160 passed (1 check needs `desktop-file-validate`, not installed) | 160 passed |
| `install.sh --uninstall` removes the launcher and both menu files | yes | yes |

What this run found: Ubuntu 23.10+ stops a normal user from creating the unprivileged namespaces `tests.sh` uses, so two tests failed there. The product itself is not affected (it builds its namespace through sudo, and the self-test passes). The suite now skips those cases with a note and the command to enable them.

## 2. The automated tests

`bash tests.sh` (launcher, 108 checks) and `bash install-tests.sh` (installer, 161 checks). No sudo, no internet. Nothing outside temp folders is changed.

**Launcher tests** use `unshare` to build throwaway network namespaces that copy vopono's real WireGuard layout (a WireGuard device, `table 51820`, the fwmark rule, `suppress_prefixlength 0`, a veth default route), plus broken versions of it, and a stand-in `vopono` and browser. They cover:

- the config file is parsed, never run; unknown keys are errors;
- dead VPN servers are detected and swapped, up to 3 tries, never the same one twice;
- your own WireGuard files: 18 accepted/refused cases matching the exact grammar vopono 1.0.2 reads, plus ownership, permissions and NUL bytes; refused files are never printed;
- OpenVPN files in your own folder are refused outright (OpenVPN runs as root and a config file can make it run programs);
- on a split-tunnel route, a half-split (`0.0.0.0/1` + `128.0.0.0/1`) route, or no tunnel at all: `SECURITY` error, the browser never starts, no retry;
- `HOME` and `TMPDIR` are inside the RAM folder;
- the inner step refuses to run on the host's own network, and refuses when it cannot tell;
- VPN keys never appear in error output;
- no RAM folders are left behind.

**Installer tests** run the whole installer against fake systems (stand-ins for `sudo`, `apt-get`, `dpkg`, and so on; the real `gpg`; the real `apt` only to list a fake system's sources). They cover:

- a doctored Mullvad key is never installed: wrong key, a second key appended, a key hidden in a non-PGP block, a key hidden after the checksum line, a secret-key block. Only gpg's own clean copy of the one right key is ever installed;
- a tampered vopono download is refused;
- files swapped by another program between the check and the install change nothing that gets installed;
- an existing Mullvad package source is used only if it is byte for byte the line the installer writes; 20+ unsafe variants are refused before `sudo` is ever called (`trusted=yes`, plain http, hidden characters, comma lists, other files, unreadable files);
- the package must come only from Mullvad's repository, as root's `apt` sees it;
- dry runs change nothing; re-runs change nothing; edited files are kept as backups; uninstall removes only what the installer wrote;
- refusals: wrong Linux family, wrong CPU, root, Ghost Browser running, no terminal, no sudo.

## 3. The tests were tested (mutation)

A rule was broken on purpose in a copy of the code, and the tests were run on the copy. If they still passed, the tests were not guarding that rule.

| Code | Rules broken, one at a time | Caught |
|---|---|---|
| Launcher | 15 (route check, namespace check, full-tunnel rule, ASCII/NUL/owner/permission rules, key hiding, RAM temp folder, and more) | 15 |
| Installer | 12 (owner checks, exact-file rule, byte comparison of key and source line, warnings-fail-closed, root's-view check, link check, language-proof parsing, and more) | 11. The twelfth is covered by a second rule (the byte comparison), so breaking it alone changes nothing |

Reviewers also ran their own mutation passes each round; every survivor they found got a test.

## 4. Independent review, including what went wrong

Each round: several reviewers attack the code from different angles; every finding then goes to a sceptic whose job is to **disprove** it by reproducing it. Only reproduced findings count.

| Code | Round | Confirmed | Worst | What it led to |
|---|---|---|---|---|
| Launcher | 1 | 24 | not recorded | First fix for "OpenVPN files run programs as root" was a blocklist; beaten by quoted option names, NUL bytes and library loading |
| Launcher | 2 | 13 | not recorded | Second fix, an allowlist, also beaten three ways. **OpenVPN files removed from user folders entirely** |
| Launcher | 3 | 12 | low | Small fixes |
| Installer | 1 | 30 | **critical** | A key file could hide a second key in a block `gpg` skips but `apt` reads. Fix: never install the downloaded file, install gpg's clean copy |
| Installer | 2 | 26 | **critical** | Same trick another way (after the checksum line), for key files already on the system. Fix: byte-identity with the published key |
| Installer | 3 | 27 | high | Install failed on non-English systems; more ways to write an unsafe source that the parser read as safe. Fix: **the parser was deleted**; only the installer's own exact line is accepted |
| Installer | 4 | 18 | medium | A source file the user can't read was invisible to the check. Fix: any `apt` warning fails closed; the final check uses root's view |

150 confirmed findings in total, 1 refuted. The pattern in the two worst bugs was the same: **a check that reads a file differently from the program that later uses it can be fooled.** Both times, parsing harder didn't fix it. Removing the thing being parsed did.

The fixes after installer round 4 were checked by tests and mutation, not by a fifth review round.

## 5. Not verified, known limits, known traces

- **Only one setup has had a real VPN launch:** the one in section 1. The clean-machine runs in section 1b had no VPN account and no desktop session, so the menu entry, the password popup and a real browser window were not exercised there.
- **vopono's code was read, not audited.** The launcher relies on vopono 1.0.2's kill switch (`wireguard.rs`, `exec.rs`); the order (namespace, routes, tunnel + firewall, then the application) was confirmed from source and by the live test, and the version is pinned by SHA-256.
- **Provider-synced VPN files are not opened** by the launcher (they hold your VPN key); for those, the route check inside the namespace is the guard.
- **Not a sandbox.** The browser runs as your user and shares your desktop session (X11 or Wayland, the session D-Bus). A link handed to another running app would open outside the VPN.
- **Swap.** Memory pages can be written to an unencrypted swap file or partition.
- **`/tmp/MullvadUpdateLock-<hash>`**: Mullvad Browser creates this empty file at start at a fixed path and removes it on close. After a crash it remains; its timestamp shows when the browser started.
- **Your password is needed at every launch**, because building a network namespace needs root. The launcher adds no sudo rule to avoid this, on purpose.
