#!/usr/bin/env bats
#
# Unit tests for the pure/deterministic helper functions in bin/vpnctl.
#
# These source the script (rather than exec it) so its functions can be
# called directly — see the VPNCTL_SOURCED guard near the top of bin/vpnctl,
# which skips the final subcommand dispatch when the file is sourced instead
# of executed. VPNCLI_CONFIG_DIR/VPNCLI_STATE_DIR are always pointed at a
# throwaway temp dir so tests never touch a real ~/.config or ~/.local/state.
#
# Anything that shells out to the OS secret store, a real VPN binary, or
# /etc/sudoers.d is covered with disposable fakes in integration.bats instead.

setup() {
    VPNCTL="${BATS_TEST_DIRNAME}/../bin/vpnctl"
    TEST_TMP="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/vpnctl-test.XXXXXX")"
    export VPNCLI_CONFIG_DIR="$TEST_TMP/config"
    export VPNCLI_STATE_DIR="$TEST_TMP/state"
    # shellcheck disable=SC1090
    source "$VPNCTL"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# --- sourcing guard ---------------------------------------------------------

@test "sourcing the script does not dispatch a subcommand" {
    [ "$VPNCTL_SOURCED" -eq 1 ]
}

@test "usage includes the title logo and version" {
    run "$VPNCTL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"V   V PPPP  N   N  CCCC  L      I"* ]]
    [[ "$output" == *"vpnctl — self-supervising VPN tunnel manager"* ]]
    [[ "$output" == *"Version: 0.1.16"* ]]
    [[ "$output" == *"Usage: vpnctl <command>"* ]]
}

@test "version command prints the current version without configuration checks" {
    VPN_TYPE=invalid
    run "$VPNCTL" --version
    [ "$status" -eq 0 ]
    [ "$output" = "vpnctl 0.1.16" ]
}

# --- secret_account / secret_account_legacy (per-backend scoping) ----------

@test "secret_account scopes the password account to VPN_TYPE" {
    VPN_TYPE=fortivpn
    [ "$(secret_account password)" = "${USER}-fortivpn" ]
    VPN_TYPE=openvpn
    [ "$(secret_account password)" = "${USER}-openvpn" ]
}

@test "secret_account scopes the otp account to VPN_TYPE separately from password" {
    VPN_TYPE=openvpn
    [ "$(secret_account otp)" = "${USER}-openvpn-totp" ]
    [ "$(secret_account otp)" != "$(secret_account password)" ]
}

@test "secret_account_legacy is backend-agnostic" {
    VPN_TYPE=fortivpn
    a="$(secret_account_legacy password)"
    VPN_TYPE=openvpn
    b="$(secret_account_legacy password)"
    [ "$a" = "$b" ]
    [ "$a" = "$USER" ]
}

# --- file_kv_set / conf_set (pure-bash, no sed) -----------------------------

@test "file_kv_set updates an existing key in place" {
    printf 'host = old.example.com\nport = 443\n' > "$TEST_TMP/f"
    file_kv_set "$TEST_TMP/f" host new.example.com
    run cat "$TEST_TMP/f"
    [[ "$output" == *"host = new.example.com"* ]]
    [[ "$output" == *"port = 443"* ]]
}

@test "file_kv_set appends the key if absent" {
    printf 'port = 443\n' > "$TEST_TMP/f"
    file_kv_set "$TEST_TMP/f" host new.example.com
    run cat "$TEST_TMP/f"
    [[ "$output" == *"host = new.example.com"* ]]
}

@test "file_kv_set does not corrupt values containing sed-special characters" {
    printf 'host = old\n' > "$TEST_TMP/f"
    file_kv_set "$TEST_TMP/f" host 'a&b|c\d'
    run cat "$TEST_TMP/f"
    [[ "$output" == *'host = a&b|c\d'* ]]
}

# --- settings_set ------------------------------------------------------------

@test "settings_set persists and round-trips a value with spaces" {
    settings_set VPN_TYPE openvpn
    run cat "$SETTINGS_FILE"
    [[ "$output" == *"VPN_TYPE=openvpn"* ]]
}

# --- sudoers_escape / render_template (replaces the old sed renderer) ------

@test "sudoers_escape escapes sudoers wildcard and separator characters" {
    run sudoers_escape 'a,b:c=d*e?f[g]h\i'
    [ "$output" = 'a\,b\:c\=d\*e\?f\[g\]h\\i' ]
}

@test "sudoers_escape leaves ordinary path characters untouched" {
    run sudoers_escape '/opt/homebrew/bin/openfortivpn'
    [ "$output" = '/opt/homebrew/bin/openfortivpn' ]
}

@test "render_template substitutes placeholders without sed delimiter corruption" {
    printf '__USER__ ALL=(root) NOPASSWD: __BIN__ -c __CFG__\n' > "$TEST_TMP/tmpl"
    out="$(render_template "$TEST_TMP/tmpl" \
        "__USER__=alice" \
        "__BIN__=$(sudoers_escape '/usr/bin/open|vpn')" \
        "__CFG__=$(sudoers_escape '/tmp/a=b*c')")"
    [ "$out" = 'alice ALL=(root) NOPASSWD: /usr/bin/open|vpn -c /tmp/a\=b\*c' ]
}

@test "a render_template'd sudoers rule with special chars passes visudo -cf" {
    command -v visudo >/dev/null 2>&1 || skip "visudo not available"
    printf '__USER__ ALL=(root) NOPASSWD: __BIN__ -c __CFG__\n' > "$TEST_TMP/tmpl"
    render_template "$TEST_TMP/tmpl" \
        "__USER__=alice" \
        "__BIN__=$(sudoers_escape '/usr/bin/openfortivpn')" \
        "__CFG__=$(sudoers_escape '/tmp/a=b*c,d:e')" \
        > "$TEST_TMP/out"
    run visudo -cf "$TEST_TMP/out"
    [ "$status" -eq 0 ]
}

@test "sudo_has_nopasswd requires an exact command spec" {
    sudo() {
        printf '%s\n' 'User may run the following commands on host:' \
            '    (root) NOPASSWD: /usr/bin/helper status /var/run/vpn.pid --extra'
    }
    ! sudo_has_nopasswd '/usr/bin/helper status /var/run/vpn.pid'
}

@test "sudo_has_nopasswd accepts sudoers-escaped command specs" {
    sudo() {
        printf '%s\n' 'User may run the following commands on host:' \
            '    (root) NOPASSWD: /usr/bin/helper status /tmp/vpn\=pid'
    }
    sudo_has_nopasswd '/usr/bin/helper status /tmp/vpn=pid'
}

# --- monitor_pid / _pid_is_monitor (pid-reuse hardening) --------------------

@test "monitor_pid fails when PID_FILE is absent" {
    run monitor_pid
    [ "$status" -ne 0 ]
}

@test "monitor_pid fails on a non-numeric pid file (never calls kill/ps on garbage)" {
    mkdir -p "$STATE_DIR"
    printf 'not-a-pid\n' > "$PID_FILE"
    run monitor_pid
    [ "$status" -ne 0 ]
}

@test "monitor_pid rejects a live pid whose cmdline is not our monitor (pid-reuse case)" {
    mkdir -p "$STATE_DIR"
    sleep 5 &
    unrelated_pid=$!
    echo "$unrelated_pid" > "$PID_FILE"
    run monitor_pid
    [ "$status" -ne 0 ]
    kill "$unrelated_pid" 2>/dev/null
}

@test "monitor_pid rejects a live process that only mentions PROG __run__" {
    mkdir -p "$MONITOR_LOCK_DIR"
    token="monitor-token"
    printf '%s %s %s\n' "$token" "$$" "$(date +%s)" > "$MONITOR_OWNER_FILE"
    bash -c 'while :; do sleep 5; done' "$PROG" __run__ "$token" &
    unrelated_pid=$!
    sleep 0.3
    echo "$unrelated_pid" > "$PID_FILE"
    run monitor_pid
    [ "$status" -ne 0 ]
    kill "$unrelated_pid" 2>/dev/null
}

@test "monitor_pid accepts a live pid whose cmdline matches PROG __run__ and its token" {
    mkdir -p "$MONITOR_LOCK_DIR"
    fake="$TEST_TMP/$PROG"
    printf '#!/usr/bin/env bash\nsleep 5\n' > "$fake"
    chmod +x "$fake"
    # The helper identifies the resolved executable path and unique token.
    PROG="$(basename "$fake")"
    SELF="$fake"
    token="monitor-token"
    MONITOR_TOKEN="$token"
    printf '%s %s %s\n' "$token" "$$" "$(date +%s)" > "$MONITOR_OWNER_FILE"
    "$fake" __run__ "$token" &
    fake_pid=$!
    sleep 0.3
    echo "$fake_pid" > "$PID_FILE"
    run monitor_pid
    [ "$status" -eq 0 ]
    [ "$output" = "$fake_pid" ]
    kill "$fake_pid" 2>/dev/null
}

# --- monitor startup lock / readiness ----------------------------------------

@test "acquire_monitor_lock is atomic and records an owner token" {
    acquire_monitor_lock
    [ -d "$MONITOR_LOCK_DIR" ]
    [ "$(awk '{print $1}' "$MONITOR_OWNER_FILE")" = "$MONITOR_TOKEN" ]
    run acquire_monitor_lock
    [ "$status" -eq 2 ]
    cleanup_monitor_state
}

@test "wait_for_monitor_ready requires the matching token and pid" {
    mkdir -p "$STATE_DIR"
    sleep 5 &
    child_pid=$!
    write_monitor_state "$MONITOR_READY_FILE" "wrong ready $child_pid"
    STARTUP_TIMEOUT=1
    run wait_for_monitor_ready expected-token "$child_pid"
    [ "$status" -ne 0 ]
    kill "$child_pid" 2>/dev/null
}

@test "real __run__ dispatch passes the monitor token to run_monitor" {
    mkdir -p "$CONFIG_DIR" "$MONITOR_LOCK_DIR"
    printf '#!/bin/sh\nexit 1\n' > "$TEST_TMP/secret-tool"
    chmod +x "$TEST_TMP/secret-tool"
    PATH="$TEST_TMP:$PATH"
    export PATH
    printf 'VPN_TYPE=fortivpn\nOPENFORTIVPN=/definitely/missing/openfortivpn\nSECRET_BACKEND=secret-tool\n' \
        > "$SETTINGS_FILE"
    token="dispatch-token"
    printf '%s %s %s\n' "$token" "$$" "$(date +%s)" > "$MONITOR_OWNER_FILE"

    run "$VPNCTL" __run__ "$token"
    [ "$status" -ne 0 ]
    [[ "$output" != *"monitor startup lock is not owned"* ]]
    [[ "$(cat "$LOG_FILE")" == *"no VPN password in the secret store"* ]]
}

# --- vpn_inet dispatch -------------------------------------------------------

@test "vpn_inet dispatches to tun_inet for openvpn and ppp_inet otherwise" {
    VPN_TYPE=openvpn
    tun_inet() { echo "tun-called"; return 0; }
    ppp_inet() { echo "ppp-called"; return 0; }
    run vpn_inet
    [ "$output" = "tun-called" ]

    VPN_TYPE=fortivpn
    run vpn_inet
    [ "$output" = "ppp-called" ]
}

# --- settings validation -----------------------------------------------------

@test "validate_settings rejects an unknown backend instead of treating it as fortivpn" {
    VPN_TYPE=wireguard
    run validate_settings
    [ "$status" -ne 0 ]
    [[ "$output" == *"VPN_TYPE"* ]]
}

@test "validate_settings rejects invalid secret backend and timing values" {
    SECRET_BACKEND=keychain
    run validate_settings
    [ "$status" -ne 0 ]

    SECRET_BACKEND=auto
    INTERVAL=0
    run validate_settings
    [ "$status" -ne 0 ]
}

@test "validate_settings accepts supported backend and settings values" {
    VPN_TYPE=openvpn
    SECRET_BACKEND=auto
    INTERVAL=10
    CONNECT_GRACE=20
    HALF_OPEN_CHECKS=3
    MAX_LOG_BYTES=1048576
    STARTUP_TIMEOUT=30
    TUN_IFACE=utun4
    run validate_settings
    [ "$status" -eq 0 ]
}

@test "setup repairs an invalid secret backend before password setup" {
    SECRET_BACKEND=keychain
    SETTINGS_FILE="$TEST_TMP/settings"
    CONFIG_DIR="$TEST_TMP"
    OS=Linux
    printf '\n' | repair_secret_backend
    [[ "$(cat "$SETTINGS_FILE")" == *"SECRET_BACKEND=auto"* ]]
}

# --- resolve_active_backend --------------------------------------------------

@test "resolve_active_backend computes distinct sudoers paths per backend" {
    VPN_TYPE=fortivpn
    resolve_active_backend
    fortivpn_path="$ACTIVE_SUDOERS_PATH"
    VPN_TYPE=openvpn
    resolve_active_backend
    openvpn_path="$ACTIVE_SUDOERS_PATH"
    [ "$fortivpn_path" != "$openvpn_path" ]
    [[ "$fortivpn_path" == *"-fortivpn" ]]
    [[ "$openvpn_path" == *"-openvpn" ]]
}
