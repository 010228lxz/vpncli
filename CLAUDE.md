# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A cross-platform CLI (macOS Intel/ARM + Linux) that brings up and self-supervises an
`openfortivpn` SSL-VPN tunnel. There is no build step, no test suite, and no package manager —
it's a `bash` control script plus an `expect` helper, distributed as a Homebrew formula.
"Running" it means invoking subcommands of `vpnctl`.

## Commands

```sh
bin/vpnctl setup            # first-run bootstrap: config + password + sudoers, then doctor
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

## Architecture

The repo is laid out for Homebrew, separating read-only **code** from per-machine
**config/state** so it survives being installed to a brew prefix:

- **`bin/vpnctl`** — the whole CLI *and* the monitor daemon in one `bash` file. Subcommands
  dispatch at the bottom `case`. Function definitions come first; a small **post-config
  resolution** block near the end (after the functions, before the `case`) computes `PKILL`,
  `OPENFORTIVPN`, `EXPECT_SCRIPT`, and `SECRET_BACKEND_RESOLVED`.
- **`libexec/fortiVPN.expect`** — spawns `sudo <openfortivpn> -c <config>` and answers the VPN
  password prompt. **Takes the openfortivpn path and config path as argv** (`fortiVPN.expect
  <bin> <config>`) so the spawned command matches the generated sudoers rule on any machine.
  Stays attached (`expect eof`) for the tunnel's lifetime, so killing it kills the tunnel.
- **`share/vpn.conf.example`** — scrubbed config template (no real values).
- **`share/vpncli.sudoers.template`** — placeholdered sudoers rule, rendered per machine.
- **`Formula/vpncli.rb`** — Homebrew formula for a tap.

### Paths: code vs config vs state

- **Code** is found relative to the script's **symlink-resolved** real path (a `readlink` loop
  handles Homebrew's `bin` symlink and a plain clone). `find_asset` searches a candidate list
  (`../libexec`, `../share/vpncli` (pkgshare), `../share`, same-dir, `..`) so both the installed
  and the cloned layouts work.
- **Config**: `${VPNCLI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/vpncli}` — holds
  `vpn.conf` and an optional sourced `settings` file.
- **State**: `${VPNCLI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vpncli}` — holds
  `vpn.pid` and `vpn.log` (+ `vpn.log.1`).

### Customization (`settings` file)

`~/.config/vpncli/settings` is sourced if present and overrides the defaults set at the top of
the script: `OPENFORTIVPN` (else auto-detected), `SECRET_SERVICE`, `SECRET_BACKEND`,
`INTERVAL`, `CONNECT_GRACE`, `HALF_OPEN_CHECKS`, `MAX_LOG_BYTES`, `SUDOERS_PATH`. This is the
intended way to tune behavior — avoid hardcoding new constants in the script.

### Monitor loop (`run_monitor`)

Polls every `INTERVAL` (10s) and distinguishes two failure modes:
- **No process** → reconnect immediately, then `sleep CONNECT_GRACE` (20s) to let the tunnel
  come up before re-checking.
- **Process alive but no `ppp` interface** ("half-open") → tolerate `HALF_OPEN_CHECKS` (3)
  consecutive polls before forcing a reconnect, so a tunnel that's merely still negotiating
  isn't killed.

"Healthy" (`vpn_healthy`) means *both* the openfortivpn process is alive *and* a `ppp`
interface has an inet address. `ppp_inet` scans only `ppp[0-9]*` interfaces (openfortivpn uses
pppd → `ppp0` on both OSes), so it ignores unrelated `utun*`/other VPNs.

### OS abstraction

OS-specific calls go through thin dispatchers keyed on `OS="$(uname -s)"`:
`secret_get`/`secret_set`/`secret_present` (`security` ↔ `secret-tool`/`pass`), `ppp_inet` and
`net_default_iface` (`ifconfig`/`route`/`netstat` ↔ `ip`), `file_size` (`wc -c`, portable),
`detect_openfortivpn`. Keep new platform-specific logic inside these helpers, not inline.

### Security model (read before touching credentials)

The design keeps secrets out of `ps` and out of sudo prompts:
- The VPN password lives in the OS secret store under service `SECRET_SERVICE` (default
  `vpncli`), exported as `VPN_PASSWORD` so `fortiVPN.expect` reads it from the environment,
  never from argv. **There is no `vpn_<password>` prefix hack** (the old design stripped a
  leading `login_` segment; the raw password is now stored and read verbatim).
- **Passwordless sudo is generated per machine, never committed.** `do_install_sudoers` renders
  `vpncli.sudoers.template` with the detected user / openfortivpn path / config path / pkill
  path, validates with `visudo -cf`, then `sudo install -m 0440`s it to `$SUDOERS_PATH`. Both
  the launch (`-c`) and teardown (`pkill -f`) lines are rendered from the same paths the tool
  actually runs, so they always match.
- `teardown_tunnel` uses `sudo -n` (non-interactive) so the backgrounded monitor can't block on
  a prompt; `do_stop`'s fallback `pkill` may prompt interactively.
- Files the tool writes are owner-only (`umask 077` at the top; `setup` also `chmod 700`s the
  config/state dirs). `secret_set` pipes the password on stdin for `secret-tool`/`pass` (off
  argv); on macOS it uses `security -w "$pw"`, which exposes the value in that one `security`
  invocation's argv briefly — a one-time, local, interactive trade-off (a bare `-w` can't be
  used: `security` then prompts on the tty and ignores stdin when a terminal is attached).
- **Multi-user caveat:** the NOPASSWD rule runs openfortivpn as root against a *user-writable*
  config, and openfortivpn forwards options to pppd — so a writable config is a root-code-exec
  path. Harmless for the intended already-admin user; for a non-admin grantee, root-own the
  config (see README "Shared or multi-user hosts"). `do_install_sudoers` also refuses paths
  containing whitespace, which would break the literal sudoers match.

## Gotcha: verifying NOPASSWD correctly

`sudo -n -l <cmd>` is **not** a valid passwordless-sudo check — it returns success for anything
the user may run *with* a password (e.g. a blanket `(ALL) ALL`). Use `sudo_has_nopasswd`, which
parses the full `sudo -n -l` listing for an explicit `NOPASSWD:` entry matching the exact
command. `do_start` and `doctor` both rely on this; don't regress it back to `sudo -l <cmd>`.

## Gotcha: sudoers must match the spawned command exactly

Passwordless sudo only applies to the exact rendered command line. The fix for portability is
that the rule is *generated*, so moving the repo or switching the openfortivpn path can't
silently desync it — but you **must re-run `install-sudoers`** after changing `OPENFORTIVPN`,
`VPNCLI_CONFIG_DIR`, or the config path, then confirm with `doctor`.

## State / generated files (not source)

`vpn.pid`, `vpn.log`(`.1`) under the state dir; the rendered file at `$SUDOERS_PATH`. An
untracked repo-local `vpn.conf` may exist as migration input for `setup` (gitignored). These
are runtime artifacts, not source.
