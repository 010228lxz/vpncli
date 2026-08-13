# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A cross-platform CLI (macOS Intel/ARM + Linux) that brings up and self-supervises a VPN tunnel
using one of two interchangeable **backends**: `openfortivpn` (FortiClient-style SSL-VPN) or
`openvpn`. There is no build step, no test suite, and no package manager — it's a `bash` control
script plus an `expect` helper (fortivpn backend only), distributed as a Homebrew formula.
"Running" it means invoking subcommands of `vpnctl`.

## Commands

```sh
bin/vpnctl setup            # first-run bootstrap: pick backend, config + password + sudoers, then doctor
bin/vpnctl start            # spawn the background monitor (daemonizes itself)
bin/vpnctl stop             # kill the monitor; its trap tears down the tunnel
bin/vpnctl restart
bin/vpnctl status           # monitor + tunnel state
bin/vpnctl routes           # show VPN routes, and whether it's FULL or SPLIT tunnel
bin/vpnctl logs [-f]        # tail the log (-f to follow)
bin/vpnctl doctor           # diagnostics — run this first when anything is wrong
bin/vpnctl set-password     # (re)store the VPN password in the OS secret store
bin/vpnctl install-sudoers  # (re)render + install the passwordless-sudo rule
bin/vpnctl uninstall-sudoers
```

(After `brew install` or a PATH symlink it's just `vpnctl`.) `doctor` is the primary
debugging entry point. `setup` is the per-machine bootstrap Homebrew can't do (it writes the
secret store and `/etc/sudoers.d`). `__run__` is an **internal** subcommand — `do_start`
re-execs the script as `$SELF __run__` under `nohup` to become the monitor daemon.

## Backend selection (`VPN_TYPE`)

`VPN_TYPE` (`fortivpn` default, or `openvpn`) is a `settings`-file tunable, not a CLI flag —
consistent with every other tunable (see Customization below). Nearly everything in `bin/vpnctl`
that used to hardcode fortivpn-specific values now branches on `VPN_TYPE` or reads one of the
**generic post-resolution variables** computed once near the bottom of the script:

- `ACTIVE_BIN` — the resolved binary for the active backend (`$OPENFORTIVPN` or `$OPENVPN`).
- `ACTIVE_CONFIG` — the active backend's config file path (`$CONFIG_PATH` = `vpn.conf`, or
  `$OPENVPN_CONFIG_PATH` = `vpn.ovpn`). This doubles as the process fingerprint (see gotcha below)
  regardless of backend.
- `ACTIVE_LAUNCH_CMD` — the exact literal command line sudo must grant NOPASSWD on (differs in
  shape per backend; see Security model). Used by `sudo_has_nopasswd` in both `do_start` and
  `do_doctor`.

`tunnel_running`, `teardown_tunnel`, `require_config`, `do_start`, `do_stop`, and `do_doctor` all
key off these three instead of re-branching on `VPN_TYPE` themselves. Functions that *do* still
branch explicitly on `VPN_TYPE`: `launch_tunnel` (dispatches to `launch_fortivpn`/`launch_openvpn`),
`vpn_inet` (dispatches to `ppp_inet`/`tun_inet`), `do_install_sudoers` (different template/sed per
backend), and `do_setup`/`do_doctor` (different config-file validation per backend).

## Architecture

The repo is laid out for Homebrew, separating read-only **code** from per-machine
**config/state** so it survives being installed to a brew prefix:

- **`bin/vpnctl`** — the whole CLI *and* the monitor daemon in one `bash` file. Subcommands
  dispatch at the bottom `case`. Function definitions come first; a small **post-config
  resolution** block near the end (after the functions, before the `case`) computes `PKILL`,
  `OPENFORTIVPN`, `OPENVPN`, `EXPECT_SCRIPT`, `SECRET_BACKEND_RESOLVED`, and the `ACTIVE_*` trio
  above.
- **`libexec/fortiVPN.expect`** — (fortivpn backend only) spawns `sudo <openfortivpn> -c <config>`
  and answers the VPN password prompt. **Takes the openfortivpn path and config path as argv**
  (`fortiVPN.expect <bin> <config>`) so the spawned command matches the generated sudoers rule on
  any machine. Stays attached (`expect eof`) for the tunnel's lifetime, so killing it kills the
  tunnel. The openvpn backend has no equivalent helper: `launch_openvpn` spawns
  `sudo -n openvpn ...` directly, because credentials go in via a generated
  `--auth-user-pass <file>` instead of an interactive prompt, so there's no prompt to answer.
- **`share/vpn.conf.example`** — scrubbed fortivpn config template (key=value).
- **`share/vpn.ovpn.example`** — scrubbed openvpn config template (openvpn's own directive syntax;
  deliberately does *not* include `auth-user-pass`/inline credentials — `vpnctl` supplies those).
- **`share/vpncli.sudoers.template`** — placeholdered sudoers rule for fortivpn, rendered per
  machine.
- **`share/vpncli-openvpn.sudoers.template`** — placeholdered sudoers rule for openvpn (two lines:
  the `openvpn --config ... --auth-user-pass ...` launch, and the `pkill -f <config>` teardown).
- **`Formula/vpncli.rb`** — Homebrew formula for a tap. Its `install` block (`bin`/`libexec`/
  `pkgshare`) defines the installed layout that `find_asset` must resolve — it now installs both
  pairs of templates. `openvpn` itself is **not** a hard `depends_on` (only `openfortivpn` is);
  it's documented in `caveats` so the fortivpn-only install path stays lean. Its `test do` block
  asserts `--help`'s output contains `"Usage:"` — keep `usage()` matching that if you touch it.

### Paths: code vs config vs state

- **Code** is found relative to the script's **symlink-resolved** real path (a `readlink` loop
  handles Homebrew's `bin` symlink and a plain clone). `find_asset` searches a candidate list
  (`../libexec`, `../share/vpncli` (pkgshare), `../share`, same-dir, `..`) so both the installed
  and the cloned layouts work.
- **Config**: `${VPNCLI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/vpncli}` — holds
  `vpn.conf` (fortivpn) or `vpn.ovpn` (openvpn), plus an optional sourced `settings` file.
- **State**: `${VPNCLI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vpncli}` — holds
  `vpn.pid`, `vpn.log` (+ `vpn.log.1`), and (openvpn backend only) `openvpn.auth`, the
  `--auth-user-pass` file regenerated fresh before every launch.

### Customization (`settings` file)

`~/.config/vpncli/settings` is sourced if present and overrides the defaults set at the top of
the script: `VPN_TYPE`, `OPENFORTIVPN` / `OPENVPN` (else auto-detected), `OPENVPN_USERNAME`,
`TUN_IFACE`, `SECRET_SERVICE`, `SECRET_BACKEND`, `OTP_SEPARATOR`, `INTERVAL`, `CONNECT_GRACE`,
`HALF_OPEN_CHECKS`, `MAX_LOG_BYTES`, `SUDOERS_PATH`. This is the intended way to tune behavior —
avoid hardcoding new constants in the script. `settings_set` (a generic `KEY=value` rewriter,
parallel to `conf_set`/`file_kv_set` for `vpn.conf`) is how `do_setup` persists `VPN_TYPE` and
`OPENVPN_USERNAME` here without clobbering the rest of the file.

### Password + OTP (`secret_get`/`secret_set` "kind", `otp_now`)

Some gateways (FortiGate+RADIUS, corporate OpenVPN) require the static password immediately
followed by a rotating 6-digit TOTP code, concatenated into one string. `secret_get`/
`secret_set`/`secret_present`/`secret_delete` all take an optional **kind** argument (`password`
default, or `otp`) that's resolved to a distinct secret-store *account* via `secret_account`
(`$USER` vs `${USER}-totp`) — same `$SECRET_SERVICE`, different entry, so existing stored
passwords are unaffected by this change. `otp_now` reads the `otp`-kind secret (the TOTP *seed*,
never a code) and shells out to `oathtool --totp -b <seed>` to generate the current code.
`do_set_otp_secret`/`do_unset_otp_secret` (subcommands `set-otp-secret`/`unset-otp-secret`)
manage the seed; it's validated with a real `oathtool` call before being stored if `oathtool` is
present locally.

**Critical timing detail:** `load_credentials` (which builds `VPN_PASSWORD` = password +
`OTP_SEPARATOR` + OTP code when an `otp` secret exists) is called **inside `launch_tunnel`**, not
once at `run_monitor` startup — TOTP codes rotate every 30s and a monitor reconnect can happen far
later than when the monitor itself started, so credentials (and the OTP code specifically) must be
regenerated fresh on every single launch attempt, never cached across reconnects. Don't move
`load_credentials` back to a one-time call in `run_monitor` — that was the pre-OTP behavior and
would silently reuse a stale/expired code on reconnect.

### Monitor loop (`run_monitor`)

Polls every `INTERVAL` (10s) and distinguishes two failure modes, identically for either backend:
- **No process** → reconnect immediately, then `sleep CONNECT_GRACE` (20s) to let the tunnel
  come up before re-checking.
- **Process alive but no tunnel interface** ("half-open") → tolerate `HALF_OPEN_CHECKS` (3)
  consecutive polls before forcing a reconnect, so a tunnel that's merely still negotiating
  isn't killed.

"Healthy" (`vpn_healthy`) means *both* the VPN process is alive (`tunnel_running`, via
`pgrep -f "$ACTIVE_CONFIG"`) *and* `vpn_inet` finds an interface with an inet address.
`vpn_inet` dispatches on `VPN_TYPE`:
- `ppp_inet` (fortivpn) scans only `ppp[0-9]*` (openfortivpn uses pppd → `ppp0` on both OSes), so
  it ignores unrelated `utun*`/other VPNs — unambiguous.
- `tun_inet` (openvpn) scans `tun[0-9]*` on Linux (also unambiguous), but on macOS falls back to
  the first `utun[0-9]*` with an address — **not** unambiguous, since other things use `utun*`
  too. `TUN_IFACE` in `settings` lets a user pin the exact interface name to remove the ambiguity.

### OS abstraction

OS-specific calls go through thin dispatchers keyed on `OS="$(uname -s)"`:
`secret_get`/`secret_set`/`secret_present`/`secret_delete` (`security` ↔ `secret-tool`/`pass`),
`ppp_inet`/`tun_inet`/`vpn_inet` and `net_default_iface` (`ifconfig`/`route`/`netstat` ↔ `ip`),
`file_size` (`wc -c`, portable), `detect_openfortivpn`/`detect_openvpn`. Keep new
platform-specific logic inside these helpers, not inline.

### Security model (read before touching credentials)

The design keeps secrets out of `ps` and out of sudo prompts, for either backend:
- The VPN password lives in the OS secret store under service `SECRET_SERVICE` (default
  `vpncli`) — same store, same lookup, regardless of `VPN_TYPE`.
  - **fortivpn**: exported as `VPN_PASSWORD` so `fortiVPN.expect` reads it from the environment,
    never from argv. **There is no `vpn_<password>` prefix hack** (the old design stripped a
    leading `login_` segment; the raw password is now stored and read verbatim).
  - **openvpn**: written by `launch_openvpn` to `$OPENVPN_AUTH_FILE` (username on line 1, password
    on line 2) immediately before every launch, `chmod 600`, and passed as
    `--auth-user-pass $OPENVPN_AUTH_FILE` — never appears on argv either.
- **Passwordless sudo is generated per machine, never committed.** `do_install_sudoers` picks the
  template/placeholders for the active `VPN_TYPE` and renders (fortivpn: user / openfortivpn path
  / config path / pkill path; openvpn: user / openvpn path / `.ovpn` path / auth-file path / pkill
  path), validates with `visudo -cf`, then `sudo install -m 0440`s it to `$SUDOERS_PATH`. Both the
  launch and teardown (`pkill -f`) lines are rendered from the same paths the tool actually runs,
  so they always match.
- `teardown_tunnel` uses `sudo -n` (non-interactive) so the backgrounded monitor can't block on
  a prompt; `do_stop`'s fallback `pkill` may prompt interactively. `launch_openvpn` also uses
  `sudo -n` for the launch itself (no interactive password prompt is expected, unlike fortivpn's
  expect-mediated launch).
- Files the tool writes are owner-only (`umask 077` at the top; `setup` also `chmod 700`s the
  config/state dirs; `$OPENVPN_AUTH_FILE` is `chmod 600` on every regeneration). `secret_set`
  pipes the password on stdin for `secret-tool`/`pass` (off argv); on macOS it uses
  `security -w "$pw"`, which exposes the value in that one `security` invocation's argv briefly —
  a one-time, local, interactive trade-off (a bare `-w` can't be used: `security` then prompts on
  the tty and ignores stdin when a terminal is attached).
- **Multi-user caveat:** the NOPASSWD rule runs the VPN binary as root against a *user-writable*
  config, and both openfortivpn (via pppd) and openvpn (via `up`/`down` scripts) can execute
  arbitrary code as a side effect — so a writable config is a root-code-exec path for either
  backend. Harmless for the intended already-admin user; for a non-admin grantee, root-own the
  config (see README "Shared or multi-user hosts"). `do_install_sudoers` also refuses paths
  containing whitespace, which would break the literal sudoers match.

## Gotcha: verifying NOPASSWD correctly

`sudo -n -l <cmd>` is **not** a valid passwordless-sudo check — it returns success for anything
the user may run *with* a password (e.g. a blanket `(ALL) ALL`). Use `sudo_has_nopasswd`, which
parses the full `sudo -n -l` listing for an explicit `NOPASSWD:` entry matching the exact
command. `do_start` and `doctor` both rely on this (via `$ACTIVE_LAUNCH_CMD`); don't regress it
back to `sudo -l <cmd>`.

## Gotcha: sudoers must match the spawned command exactly

Passwordless sudo only applies to the exact rendered command line. The fix for portability is
that the rule is *generated*, so moving the repo or switching the binary path can't silently
desync it — but you **must re-run `install-sudoers`** after changing `VPN_TYPE`, `OPENFORTIVPN`/
`OPENVPN`, `VPNCLI_CONFIG_DIR`, `VPNCLI_STATE_DIR` (moves the openvpn auth-file path), or the
config path, then confirm with `doctor`.

## Gotcha: the config path doubles as the process fingerprint

There's no pid file for the VPN process itself — `tunnel_running`, `teardown_tunnel`, and
`do_stop`'s fallback all find or kill it via `pgrep -f`/`pkill -f "$ACTIVE_CONFIG"`, matching the
`-c $CONFIG_PATH` (fortivpn) or `--config $OPENVPN_CONFIG_PATH` (openvpn) argument in its command
line (see the comment in `vpn.conf.example`/`vpn.ovpn.example`). This is a second reason
(independent of sudoers matching) that the config path must stay a stable, whitespace-free,
unique string: change `VPNCLI_CONFIG_DIR` while a tunnel is running and the old process becomes
unfindable/unkillable by the new code path. For openvpn specifically, `$OPENVPN_AUTH_FILE` is
similarly fixed (under `VPNCLI_STATE_DIR`) for the same reason — it's named literally in the
sudoers rule and in every launch command.

## State / generated files (not source)

`vpn.pid`, `vpn.log`(`.1`), and (openvpn backend) `openvpn.auth` under the state dir; the
rendered file at `$SUDOERS_PATH`. An untracked repo-local `vpn.conf` may exist as migration input
for `setup` (gitignored). These are runtime artifacts, not source.
