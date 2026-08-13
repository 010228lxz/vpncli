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
brew install 010228lxz/vpncli/vpncli   # stable v0.1.0 (add --HEAD to track main instead)
vpnctl setup                           # finish per-machine setup
```

The explicit tap URL is needed because the repo is named `vpncli`, not
`homebrew-vpncli` — Homebrew's short `brew tap <user>/<name>` form assumes the
`homebrew-` prefix.

### From a clone (no Homebrew)

```sh
git clone https://github.com/010228lxz/vpncli.git && cd vpncli
./bin/vpnctl setup
# optionally symlink onto your PATH:
ln -s "$PWD/bin/vpnctl" /usr/local/bin/vpnctl
```

### Dependencies

Pick one backend (set via `VPN_TYPE` — see Customization below):

- **fortivpn** (default): `openfortivpn` (`brew install openfortivpn` / `apt install
  openfortivpn`) + `expect` (preinstalled on macOS; `apt install expect` on Linux).
- **openvpn**: `openvpn` (`brew install openvpn` / `apt install openvpn-client`).
  No `expect` needed — credentials are passed via a freshly generated
  `--auth-user-pass` file instead of an interactive prompt.

Either way, you also need a secret store: macOS **Keychain** (built in), or on
Linux [`secret-tool`](https://wiki.gnome.org/Projects/Libsecret) (libsecret) or
[`pass`](https://www.passwordstore.org/). Auto-detection prefers `secret-tool`
only when a desktop session bus is present and otherwise falls back to `pass`,
so it works on headless servers; force a choice with `SECRET_BACKEND`.

## Usage

```sh
vpnctl setup            # first run: pick a backend, config + password + sudoers, then doctor
vpnctl start            # spawn the background monitor (daemonizes)
vpnctl stop             # stop the monitor; its trap tears the tunnel down
vpnctl restart
vpnctl status           # monitor + tunnel state
vpnctl routes           # VPN routes, and whether it's a FULL or SPLIT tunnel
vpnctl logs [-f]        # show / follow the log
vpnctl doctor           # diagnostics — run this first when anything is wrong
vpnctl set-password     # (re)store the VPN password in the secret store
vpnctl set-otp-secret   # (re)store a TOTP seed for password+OTP gateways
vpnctl unset-otp-secret # remove the stored TOTP seed
vpnctl install-sudoers  # (re)install the passwordless-sudo rule
vpnctl uninstall-sudoers
```

`doctor` is the primary debugging entry point. `setup` is the one-time bootstrap
Homebrew can't do for you (it writes the secret store and `/etc/sudoers.d`).

## Choosing a backend

Set `VPN_TYPE` in `~/.config/vpncli/settings` (or answer the prompt in
`vpnctl setup`):

| | `VPN_TYPE=fortivpn` (default) | `VPN_TYPE=openvpn` |
|---|---|---|
| Binary | `openfortivpn` | `openvpn` |
| Config file | `~/.config/vpncli/vpn.conf` (key=value) | `~/.config/vpncli/vpn.ovpn` (provider-supplied) |
| Password delivery | `expect` answers the VPN password prompt | `--auth-user-pass <file>`, regenerated fresh on every launch |
| Username | `username =` line in `vpn.conf` | `OPENVPN_USERNAME` in `settings` |
| Tunnel interface | `ppp0` (pppd) | `tun0` (Linux) / `utun*` (macOS — see caveat below) |

For openvpn, `~/.config/vpncli/vpn.ovpn` is a real client config from your VPN
provider (certs/keys embedded or referenced by absolute path) — don't put
`auth-user-pass` or inline credentials in it; `vpnctl` supplies those itself.
See `share/vpn.ovpn.example` for the expected shape.

**macOS + openvpn caveat:** unlike `ppp0`/`tun0`, openvpn's `utun` interface name
on macOS is assigned dynamically and isn't unique to this tool (other VPNs/OS
features use `utun*` too), so tunnel-health detection is best-effort: it picks
the first `utun*` with an address. If that's ambiguous on your machine, pin the
exact interface with `TUN_IFACE=utun4` in `settings` once you know which one
openvpn is actually using (check `vpnctl logs` or `ifconfig` after connecting).

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
store as your password (Keychain/secret-tool/pass), under a separate entry.
The seed is the same base32 string your authenticator app was given when you
scanned the QR code (often shown as text alongside the QR code during
enrollment, or extractable from the `otpauth://` URI's `secret=` parameter).

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
  interface" (tolerate a few checks, then force a reconnect).
- **`libexec/fortiVPN.expect`** — (fortivpn backend only) spawns
  `sudo openfortivpn -c <config>` and feeds it the VPN password from the
  environment. Stays attached for the tunnel's life.
- **openvpn backend** — `vpnctl` launches `sudo openvpn --config <vpn.ovpn>
  --auth-user-pass <auth-file>` directly (no interactive prompt needed); the
  auth file is regenerated from the secret store immediately before each launch.
- **`share/vpn.conf.example`** / **`share/vpn.ovpn.example`** — config templates
  for each backend.
- **`share/vpncli.sudoers.template`** / **`share/vpncli-openvpn.sudoers.template`**
  — rendered per machine by `install-sudoers`, for the active backend.

### Where things live

| | Path | Override |
|---|---|---|
| Config + `settings` | `${XDG_CONFIG_HOME:-~/.config}/vpncli/` | `VPNCLI_CONFIG_DIR` |
| Log + pid | `${XDG_STATE_HOME:-~/.local/state}/vpncli/` | `VPNCLI_STATE_DIR` |
| Code | the install prefix (read-only) | — |

## Customization

Drop a `settings` file next to your config (`~/.config/vpncli/settings`) to
override any default without editing code; it's sourced by `vpnctl`:

```sh
VPN_TYPE=fortivpn                           # fortivpn | openvpn
OPENFORTIVPN=/usr/local/bin/openfortivpn     # default: auto-detected
OPENVPN=/usr/local/sbin/openvpn              # default: auto-detected (openvpn backend)
OPENVPN_USERNAME=your.username               # auth-user-pass username (openvpn backend)
TUN_IFACE=                                   # pin the tunnel iface (openvpn on macOS)
SECRET_SERVICE=vpncli                       # secret store service/account label
SECRET_BACKEND=auto                         # auto | security | secret-tool | pass
OTP_SEPARATOR=                               # inserted between password and OTP code
                                              # (see "Password + OTP" above)
INTERVAL=10                                 # health-check interval (s)
CONNECT_GRACE=20                            # grace after a (re)connect (s)
HALF_OPEN_CHECKS=3                          # half-open polls before forcing reconnect
MAX_LOG_BYTES=1048576                       # log rotation threshold
SUDOERS_PATH=/etc/sudoers.d/vpncli          # where the generated rule installs
```

After changing `VPN_TYPE`, `OPENFORTIVPN`/`OPENVPN`, or the config location,
re-run `vpnctl install-sudoers` so the passwordless rule matches the new command.

## Security model

The design keeps secrets out of the process list (`ps`) and out of sudo prompts:

- The VPN password lives in the OS secret store, never in the repo. For the
  fortivpn backend, `vpnctl` exports it as `VPN_PASSWORD` so the expect helper
  reads it from the environment, never from argv. For the openvpn backend, it's
  written to a fixed, owner-only `--auth-user-pass` file regenerated fresh
  before every launch — also never on argv.
- If a TOTP seed is configured (`set-otp-secret`), the current 6-digit code is
  generated fresh via `oathtool` immediately before every launch attempt (never
  cached, never written to disk on its own) and appended to the password in
  memory before it's exported/written to the auth file.
- **Passwordless sudo is generated per machine.** `install-sudoers` renders the
  template for the active backend with this machine's user, binary path, and
  config path (plus the auth-file path for openvpn), then validates it with
  `visudo -cf` before installing. Because the rule is generated from the exact
  command the tool runs, moving the repo can't silently desync it (the original
  hardcoded rule's main failure mode). `doctor` verifies the rule actually
  grants **NOPASSWD** — not merely "allowed with a password".
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
sudo chown root ~/.config/vpncli/vpn.conf    # fortivpn backend
sudo chmod 644  ~/.config/vpncli/vpn.conf    # edit later with sudo
# or, for the openvpn backend:
sudo chown root ~/.config/vpncli/vpn.ovpn
sudo chmod 644  ~/.config/vpncli/vpn.ovpn
```

The secret store and `set-password` are unaffected by this.

## Uninstall

```sh
vpnctl stop
vpnctl uninstall-sudoers
rm -rf ~/.config/vpncli ~/.local/state/vpncli
# remove the password: macOS → Keychain Access; Linux → secret-tool/pass
brew uninstall vpncli   # if installed via Homebrew
```
