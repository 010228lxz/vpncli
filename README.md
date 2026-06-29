# vpnCLI

A small, self-supervising VPN tunnel manager built on
[`openfortivpn`](https://github.com/adrienverge/openfortivpn). `vpnctl` brings
up a FortiClient-style SSL-VPN tunnel and runs a background monitor that
reconnects automatically if the tunnel drops or goes half-open.

Runs on **macOS (Intel + Apple Silicon)** and **Linux**. No secrets live in the
repo; per-machine config and credentials are created by `vpnctl setup`.

## Install

### Homebrew (recommended)

```sh
brew tap 010228lxz/vpncli https://github.com/010228lxz/vpncli
brew install --HEAD 010228lxz/vpncli/vpncli   # or `brew install vpncli` once a release is tagged
vpnctl setup                                  # finish per-machine setup
```

(The repo is private, so tapping it requires your GitHub auth — making it public
would let `brew install` work with no extra setup. The clone method below works
over SSH today.)

### From a clone (no Homebrew)

```sh
git clone git@github.com:010228lxz/vpncli.git && cd vpncli
./bin/vpnctl setup
# optionally symlink onto your PATH:
ln -s "$PWD/bin/vpnctl" /usr/local/bin/vpnctl
```

### Dependencies

- `openfortivpn` — `brew install openfortivpn` / `apt install openfortivpn`
- `expect` — preinstalled on macOS; `apt install expect` on Linux
- A secret store: macOS **Keychain** (built in), or on Linux
  [`secret-tool`](https://wiki.gnome.org/Projects/Libsecret) (libsecret) or
  [`pass`](https://www.passwordstore.org/). Auto-detection prefers `secret-tool`
  only when a desktop session bus is present and otherwise falls back to `pass`,
  so it works on headless servers; force a choice with `SECRET_BACKEND`.

## Usage

```sh
vpnctl setup            # first run: config + password + sudoers, then doctor
vpnctl start            # spawn the background monitor (daemonizes)
vpnctl stop             # stop the monitor; its trap tears the tunnel down
vpnctl restart
vpnctl status           # monitor + tunnel state
vpnctl routes           # VPN routes, and whether it's a FULL or SPLIT tunnel
vpnctl logs [-f]        # show / follow the log
vpnctl doctor           # diagnostics — run this first when anything is wrong
vpnctl set-password     # (re)store the VPN password in the secret store
vpnctl install-sudoers  # (re)install the passwordless-sudo rule
vpnctl uninstall-sudoers
```

`doctor` is the primary debugging entry point. `setup` is the one-time bootstrap
Homebrew can't do for you (it writes the secret store and `/etc/sudoers.d`).

## How it works

- **`bin/vpnctl`** — the whole CLI *and* the monitor daemon. `start` daemonizes
  by re-execing itself (`__run__`) under `nohup`; the monitor polls every 10s and
  distinguishes "no process" (reconnect now) from "process up but no `ppp`
  interface" (tolerate a few checks, then force a reconnect).
- **`libexec/fortiVPN.expect`** — spawns `sudo openfortivpn -c <config>` and feeds
  it the VPN password from the environment. Stays attached for the tunnel's life.
- **`share/vpn.conf.example`** — the config template.
- **`share/vpncli.sudoers.template`** — rendered per machine by `install-sudoers`.

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
OPENFORTIVPN=/usr/local/bin/openfortivpn   # default: auto-detected
SECRET_SERVICE=vpncli                       # secret store service/account label
SECRET_BACKEND=auto                         # auto | security | secret-tool | pass
INTERVAL=10                                 # health-check interval (s)
CONNECT_GRACE=20                            # grace after a (re)connect (s)
HALF_OPEN_CHECKS=3                          # half-open polls before forcing reconnect
MAX_LOG_BYTES=1048576                       # log rotation threshold
SUDOERS_PATH=/etc/sudoers.d/vpncli          # where the generated rule installs
```

After changing `OPENFORTIVPN` or the config location, re-run
`vpnctl install-sudoers` so the passwordless rule matches the new command.

## Security model

The design keeps secrets out of the process list (`ps`) and out of sudo prompts:

- The VPN password lives in the OS secret store, never in the repo. `vpnctl`
  exports it as `VPN_PASSWORD` so the expect helper reads it from the
  environment, never from argv.
- **Passwordless sudo is generated per machine.** `install-sudoers` renders the
  template with this machine's user, openfortivpn path, and config path, then
  validates it with `visudo -cf` before installing. Because the rule is generated
  from the exact command the tool runs, moving the repo can't silently desync it
  (the original hardcoded rule's main failure mode). `doctor` verifies the rule
  actually grants **NOPASSWD** — not merely "allowed with a password".
- Files the tool writes (config, logs, pid) are created owner-only (`umask 077`;
  `setup` also tightens the config and state dirs to `700`).

### Shared or multi-user hosts

The passwordless rule runs `openfortivpn` as **root** against your config file,
and openfortivpn forwards options to `pppd` — so anyone who can both edit that
config and invoke the rule can execute code as root. On a personal machine where
you're already an admin, this grants nothing you couldn't already do. But if you
install the NOPASSWD rule for a **non-admin** account (or a shared service user),
treat the config as privileged — make it root-owned and not writable by that
account:

```sh
sudo chown root ~/.config/vpncli/vpn.conf
sudo chmod 644  ~/.config/vpncli/vpn.conf   # edit later with sudo
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
