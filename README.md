# vpnCLI

A small, self-supervising VPN tunnel manager that drives either
[`openfortivpn`](https://github.com/adrienverge/openfortivpn) (FortiClient-style
SSL-VPN) or [`OpenVPN`](https://openvpn.net/community/) as its backend. `vpnctl`
brings up the tunnel and runs a background monitor that reconnects automatically
if it drops or goes half-open.

Runs on **macOS (Intel + Apple Silicon)** and **Linux**. No secrets live in the
repo; per-machine config and credentials are created by `vpnctl setup`.

## Install

### Homebrew (recommended)

```sh
brew tap 010228lxz/vpncli https://github.com/010228lxz/vpncli
brew install 010228lxz/vpncli/vpncli   # stable v0.1.17 (add --HEAD to track main instead)
vpnctl setup                           # finish per-machine setup (requires sudo)
```

Install the runtime dependency for the backend you use; the formula keeps
backend dependencies optional so OpenVPN users do not install FortiVPN tools:

```sh
brew install openvpn                 # OpenVPN backend
brew install openfortivpn expect     # fortivpn backend
```

The explicit tap URL is needed because the repo is named `vpncli`, not
`homebrew-vpncli` — Homebrew's short `brew tap <user>/<name>` form assumes the
`homebrew-` prefix.

### From a clone (no Homebrew)

```sh
git clone https://github.com/010228lxz/vpncli.git && cd vpncli
./bin/vpnctl setup                    # finish per-machine setup (requires sudo)
# optionally symlink onto your PATH:
ln -s "$PWD/bin/vpnctl" /usr/local/bin/vpnctl
```

### Dependencies

Pick one backend (set via `VPN_TYPE` — see Customization below):

- **fortivpn** (default): `openfortivpn` (`brew install openfortivpn` / `sudo apt install
  openfortivpn`) + `expect` (preinstalled on macOS; `sudo apt install expect` on
  Debian/Ubuntu).
- **openvpn**: `openvpn` (`brew install openvpn` / `sudo apt install openvpn` on
  Debian/Ubuntu).
  No `expect` needed — credentials are passed via a freshly generated
  `--auth-user-pass` file instead of an interactive prompt.

Either way, you also need a secret store: macOS **Keychain** (built in), or on
Linux [`secret-tool`](https://wiki.gnome.org/Projects/Libsecret) (libsecret) or
[`pass`](https://www.passwordstore.org/). Auto-detection prefers `secret-tool`
only when a desktop session bus is present and otherwise falls back to `pass`,
so it works on headless servers; force a choice with `SECRET_BACKEND`. On
Debian/Ubuntu, install these with `sudo apt install libsecret-tools` or
`sudo apt install pass`, respectively. A new `pass` store also needs a GPG key
and must be initialized with `pass init <GPG-key-id>`.

`vpnctl setup` installs a passwordless-sudo rule for the exact VPN launch and
teardown commands, so the setup user must be allowed to run `sudo`. When the
default config directory is used, setup moves the config to `/etc/vpncli`,
installs root-owned runtime copies of the VPN executable and helper, and
configures their paths automatically. Review the security notes before using it
on a shared machine.

For passwordless sudo, the active VPN config and every parent directory must be
root-owned and not writable by group or other users. The config must also avoid
external script/plugin directives (`up`, `down`, `plugin`, `route-up`, and
similar), because those would otherwise provide root code execution. A common
secure layout is `/etc/vpncli/`; create or copy the provider config there and
set `VPNCLI_CONFIG_DIR=/etc/vpncli` in the environment before running
`vpnctl install-sudoers`. If you keep the default user-writable config under
`~/.config/vpncli`, `install-sudoers` will refuse to create the rule.

For an existing setup, run `vpnctl setup`; it moves both backend configs and
`settings` into the root-owned directory and preserves the existing values.
The invoking user must still be able to read them.

Homebrew users only need to run `vpnctl setup`; it performs the protected copy
and then installs sudoers. Re-run setup after upgrading either package so the
root-owned runtime copies are refreshed.

## Usage

```sh
vpnctl setup            # first run: pick a backend, config + password + sudoers, then doctor
vpnctl start            # spawn the background monitor (daemonizes)
vpnctl stop             # stop the monitor; its trap tears the tunnel down
vpnctl restart
vpnctl switch <backend> # switch to fortivpn|openvpn (see "Switching backends" below)
vpnctl status           # monitor + tunnel state
vpnctl routes           # VPN routes, and whether it's a FULL or SPLIT tunnel
vpnctl logs [-f]        # show / follow the log
vpnctl doctor           # diagnostics — run this first when anything is wrong
vpnctl set-password     # (re)store the VPN password in the secret store (active backend only)
vpnctl set-otp-secret   # (re)store a TOTP seed for password+OTP gateways (active backend only)
vpnctl unset-otp-secret # remove the stored TOTP seed (active backend only)
vpnctl install-sudoers  # (re)install the passwordless-sudo rule (active backend only)
vpnctl uninstall-sudoers [--all]
```

`doctor` is the primary debugging entry point. `setup` is the one-time bootstrap
Homebrew can't do for you (it writes the secret store and `/etc/sudoers.d`).

## Choosing a backend

Set `VPN_TYPE` in `~/.config/vpncli/settings` (or answer the prompt in
`vpnctl setup`):

| | `VPN_TYPE=fortivpn` (default) | `VPN_TYPE=openvpn` |
|---|---|---|
| Binary | `openfortivpn` | `openvpn` |
| Config file | `${VPNCLI_CONFIG_DIR:-~/.config/vpncli}/vpn.conf` (key=value) | `${VPNCLI_CONFIG_DIR:-~/.config/vpncli}/vpn.ovpn` (provider-supplied) |
| Password delivery | `expect` answers the VPN password prompt | `--auth-user-pass <file>`, regenerated fresh on every launch |
| Username | `username =` line in `vpn.conf` | `OPENVPN_USERNAME` in `settings` |
| Tunnel interface | `ppp0` (pppd) | `tun0` (Linux) / `utun*` (macOS — see caveat below) |

For openvpn, `${VPNCLI_CONFIG_DIR:-~/.config/vpncli}/vpn.ovpn` is a real client config from your VPN
provider (certs/keys embedded or referenced by absolute path) — don't put
`auth-user-pass` or inline credentials in it; `vpnctl` supplies those itself.
See `share/vpn.ovpn.example` for the expected shape.

The example files contain placeholder gateway values and are not working VPN
profiles. Obtain the real gateway, certificates/keys, and any provider-specific
directives from your VPN administrator. Do not run `vpnctl start` until the
placeholder config has been replaced and `vpnctl doctor` reports the required
checks as passed. For FortiVPN, the gateway certificate fingerprint must also
be filled in; for OpenVPN, referenced certificate/key paths must exist and be
readable by the root-launched client.

**macOS + openvpn caveat:** unlike `ppp0`/`tun0`, openvpn's `utun` interface name
on macOS is assigned dynamically and isn't unique to this tool (other VPNs/OS
features use `utun*` too), so tunnel-health detection is best-effort: it picks
the first `utun*` with an address. If that's ambiguous on your machine, pin the
exact interface with `TUN_IFACE=utun4` in `settings` once you know which one
openvpn is actually using (check `vpnctl logs` or `ifconfig` after connecting).
`vpnctl doctor` and `vpnctl setup` both warn about this until `TUN_IFACE` is set.

## Switching backends

Every per-backend artifact is kept **independent**, so both backends can be
provisioned at once and you can flip between them without re-entering
anything or answering a sudo prompt:

| Per-backend, never shared | fortivpn | openvpn |
|---|---|---|
| Config file | `vpn.conf` | `vpn.ovpn` |
| Password (secret store) | account `<user>-fortivpn` | account `<user>-openvpn` |
| OTP seed (secret store, optional) | account `<user>-fortivpn-totp` | account `<user>-openvpn-totp` |
| Passwordless-sudo rule | `/etc/sudoers.d/vpncli-fortivpn` | `/etc/sudoers.d/vpncli-openvpn` |

This is also why one backend needing OTP and the other not is a *non-issue*:
e.g. openvpn can require password+OTP while fortivpn stays password-only (or
vice versa) — each backend only ever looks at its own OTP account, so an OTP
secret set for one never gets appended to the other's password.

To provision the second backend, run `vpnctl setup` again and pick the other
backend at the prompt (this creates its own config/password/sudoers without
touching the backend you already have working). Once both are ready:

```sh
vpnctl switch openvpn    # or: vpnctl switch fortivpn
```

`switch` persists `VPN_TYPE` to `settings`, stops/restarts the monitor if it
was running, and re-checks readiness for the target backend — if anything
(config, password, sudoers) isn't provisioned yet, it tells you exactly what's
missing instead of failing silently.

**Upgrade note:** before per-backend scoping, both backends shared one
password/OTP account. `secret_get` still falls back to that shared legacy
account when no backend-specific one exists yet, so existing installs keep
working unchanged; running `set-password`/`set-otp-secret` while a given
backend is active migrates that backend onto its own account going forward.

## Password + OTP (2FA / RADIUS gateways)

Some gateways (common with FortiGate + RADIUS, or corporate OpenVPN setups)
don't want a static password alone — they want your password *immediately
followed by* a rotating 6-digit TOTP code (the same kind an authenticator app
like Google Authenticator/Authy generates), all as a single string. `vpnctl`
can generate that code for you automatically, so you never type it by hand:

```sh
vpnctl set-otp-secret     # store the TOTP *seed* (base32 secret), once
```

This stores the TOTP **seed** — not a 6-digit code — in the same OS secret
store as your password (Keychain/secret-tool/pass), under a separate entry
scoped to the *active* backend only (see "Switching backends" above) — e.g.
require it on openvpn while leaving fortivpn password-only, with no
cross-contamination either way. The seed is the same base32 string your
authenticator app was given when you scanned the QR code (often shown as
text alongside the QR code during enrollment, or extractable from the
`otpauth://` URI's `secret=` parameter).

Once stored, **every** connection attempt (initial `start`, and every
auto-reconnect the monitor performs) regenerates a fresh code and appends it
to your password before handing it to the backend — nothing is cached, since
TOTP codes rotate every 30 seconds and a reconnect can happen long after the
monitor started. Concatenation is `password` + `OTP_SEPARATOR` (empty by
default) + the 6-digit code; set `OTP_SEPARATOR` in `settings` if your gateway
expects a delimiter (e.g. `OTP_SEPARATOR=,`) instead of straight concatenation.

Requires [`oathtool`](https://www.nongnu.org/oath-toolkit/) (`brew install
oath-toolkit` / `apt install oathtool`) — `vpnctl doctor` checks for it and
reports whether a TOTP seed is configured. Remove it with
`vpnctl unset-otp-secret`.

## How it works

- **`bin/vpnctl`** — the whole CLI *and* the monitor daemon. `start` daemonizes
  by re-execing itself (`__run__`) under `nohup`; the monitor polls every 10s and
  distinguishes "no process" (reconnect now) from "process up but no tunnel
  interface" (tolerate a few checks, then force a reconnect). Startup uses an
  atomic state-directory lock, and `start` waits for a readiness handshake
  instead of reporting success as soon as a child is forked. The monitor's exit
  cleanup removes its lock/PID/readiness state and tears down the recorded
  tunnel; a later start reclaims stale state and stops any orphaned tunnel.
- **`libexec/fortiVPN.expect`** — (fortivpn backend only) spawns
  `sudo openfortivpn -c <config>` and feeds it the VPN password from the
  environment. Stays attached for the tunnel's life.
- **openvpn backend** — `vpnctl` launches `sudo openvpn --config <vpn.ovpn>
  --auth-user-pass <auth-file>` directly (no interactive prompt needed); the
  auth file is regenerated from the secret store immediately before each launch.
- **`share/vpn.conf.example`** / **`share/vpn.ovpn.example`** — config templates
  for each backend.
- **`share/vpncli.sudoers.template`** / **`share/vpncli-openvpn.sudoers.template`**
  — rendered per machine by `install-sudoers`, one file per backend
  (`/etc/sudoers.d/vpncli-fortivpn` / `-openvpn`), for the active backend at
  the time `install-sudoers` runs.

### Where things live

| | Path | Override |
|---|---|---|
| Config + `settings` | `${XDG_CONFIG_HOME:-~/.config}/vpncli/` | `VPNCLI_CONFIG_DIR` |
| Log + pid | `${XDG_STATE_HOME:-~/.local/state}/vpncli/` | `VPNCLI_STATE_DIR` |
| Code | the install prefix (read-only) | — |

## Customization

Drop a `settings` file next to your config (`${VPNCLI_CONFIG_DIR:-~/.config/vpncli}/settings`) to
override any default without editing code; it's sourced by `vpnctl`:

```sh
VPN_TYPE=fortivpn                           # fortivpn | openvpn
OPENFORTIVPN=/usr/local/bin/openfortivpn     # default: auto-detected
OPENVPN=/usr/local/sbin/openvpn              # default: auto-detected (openvpn backend)
OPENVPN_USERNAME=your.username               # auth-user-pass username (openvpn backend)
VPNCTL_HELPER=/usr/local/libexec/vpncli/vpnctl-helper  # root-owned helper for sudoers
TUN_IFACE=                                   # pin the tunnel iface (openvpn on macOS)
SECRET_SERVICE=vpncli                       # secret store service/account label
SECRET_BACKEND=auto                         # auto | security | secret-tool | pass
OTP_SEPARATOR=                               # inserted between password and OTP code
                                              # (see "Password + OTP" above)
INTERVAL=10                                 # health-check interval (s)
CONNECT_GRACE=20                            # grace after a (re)connect (s)
HALF_OPEN_CHECKS=3                          # half-open polls before forcing reconnect
MAX_LOG_BYTES=1048576                       # log rotation threshold
STARTUP_TIMEOUT=30                           # seconds to wait for monitor readiness
SUDOERS_PATH=/etc/sudoers.d/vpncli          # base path; the installed rule is
                                              # suffixed per backend, e.g.
                                              # /etc/sudoers.d/vpncli-fortivpn
```

Settings are validated before any command runs. `VPN_TYPE` and
`SECRET_BACKEND` must use the values shown above; timing values must be positive
integers; configured executable, directory, and sudoers paths must be absolute
and contain no whitespace; and a pinned `TUN_IFACE` must be named `tunN` or
`utunN`. Invalid settings fail with an actionable error instead of silently
selecting a different backend.

After changing `OPENFORTIVPN`/`OPENVPN`, or the config location, re-run
`vpnctl install-sudoers` so the passwordless rule matches the new command
(switching `VPN_TYPE` itself doesn't require this — see "Switching backends").

## Security model

The design keeps secrets out of the process list (`ps`) and out of sudo prompts:

- The VPN password lives in the OS secret store, never in the repo, under an
  account scoped to the active backend (see "Switching backends"). For the
  fortivpn backend, `vpnctl` exports it as `VPN_PASSWORD` so the expect helper
  reads it from the environment, never from argv. For the openvpn backend, it's
  written to a fixed, owner-only `--auth-user-pass` file regenerated fresh
  before every launch — also never on argv.
- If a TOTP seed is configured (`set-otp-secret`) for the active backend, the
  current 6-digit code is generated fresh via `oathtool` immediately before
  every launch attempt (never cached, never written to disk on its own) and
  appended to the password in memory before it's exported/written to the auth
  file.
- **Passwordless sudo is generated per machine, one rule file per backend**
  (`/etc/sudoers.d/vpncli-fortivpn`, `/etc/sudoers.d/vpncli-openvpn`) — so
  provisioning one backend never removes the other's rule. `install-sudoers`
  renders the template for the active backend with this machine's user, binary
  path, and config path (plus the auth-file path for openvpn), then validates
  it with `visudo -cf` before installing. Because the rule is generated from
  the exact command the tool runs, moving the repo can't silently desync it
  (the original hardcoded rule's main failure mode). `doctor` verifies the
  rule actually grants **NOPASSWD** — not merely "allowed with a password".
  Before generating a rule, `vpnctl` requires the active config and all parent
  directories to be root-owned, rejects symlink paths, and blocks config
  directives that can launch external scripts or plugins.
- The privileged launch/status/stop operations run through the installed,
  root-owned `vpnctl-helper`. It records the tunnel PID in `/var/run`, verifies
  that the PID command matches the expected VPN binary and config for both
  status and stop, and stops only that recorded PID rather than using a broad
  `pkill` pattern. Re-run `vpnctl install-sudoers` after upgrading so the
  generated stop rule includes those identity arguments.
- Files the tool writes (config, logs, pid, the openvpn auth file) are created
  owner-only (`umask 077`; `setup` also tightens the config and state dirs to
  `700`).

### Shared or multi-user hosts

The passwordless rule runs the VPN binary as **root** against your config file
(`openfortivpn` forwards options to `pppd`; `openvpn` can push/execute
`up`/`down` scripts referenced in the `.ovpn` file) — so anyone who can both
edit that config and invoke the rule can execute code as root. On a personal
machine where you're already an admin, this grants nothing you couldn't already
do. But if you install the NOPASSWD rule for a **non-admin** account (or a
shared service user), treat the config as privileged — make it root-owned and
not writable by that account:

```sh
sudo install -d -o root -m 755 /etc/vpncli
sudo install -o root -m 644 ~/.config/vpncli/settings /etc/vpncli/settings
sudo install -o root -m 644 ~/.config/vpncli/vpn.conf /etc/vpncli/vpn.conf
# or, for the openvpn backend:
sudo install -o root -m 644 ~/.config/vpncli/vpn.ovpn /etc/vpncli/vpn.ovpn
export VPNCLI_CONFIG_DIR=/etc/vpncli
vpnctl install-sudoers
```

`vpnctl setup` performs this move automatically when it starts with the default
user config directory. If you prepare the directory manually, keep every parent
directory root-owned and run `install-sudoers` with `VPNCLI_CONFIG_DIR=/etc/vpncli`.

The secret store and `set-password` are unaffected by this.

## Uninstall

```sh
vpnctl stop
vpnctl uninstall-sudoers --all         # removes both backends' sudoers rules
rm -rf ~/.config/vpncli ~/.local/state/vpncli
# remove the password(s): macOS → Keychain Access; Linux → secret-tool/pass
# (look for accounts <user>-fortivpn / <user>-openvpn / *-totp, and the
# legacy <user> / <user>-totp accounts if this install predates per-backend
# credentials — see "Switching backends")
brew uninstall vpncli   # if installed via Homebrew
```

## Development

No build step — `bin/vpnctl` is the whole tool. Before sending a PR:

```sh
shellcheck bin/vpnctl                  # brew install shellcheck / apt install shellcheck
bats tests/vpnctl.bats                 # brew install bats-core / apt install bats
```

`tests/vpnctl.bats` unit-tests the pure/deterministic helpers (secret account naming,
`file_kv_set`/`settings_set`, the sudoers template renderer, pid-reuse handling in
`monitor_pid`, backend dispatch) by `source`-ing `bin/vpnctl` — it never touches a
real secret store, sudo, or VPN binary. CI (`.github/workflows/ci.yml`) runs
ShellCheck, the bats suite on Linux + macOS, and a Homebrew formula audit on every
push/PR.
