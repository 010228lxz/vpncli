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
# Anything that shells out to the OS secret store (security/secret-tool/pass),
# a real VPN binary, or /etc/sudoers.d is intentionally NOT exercised here —
# those need mocked-shell / integration-style coverage, not unit tests.

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

@test "monitor_pid accepts a live pid whose cmdline matches PROG __run__" {
    mkdir -p "$STATE_DIR"
    fake="$TEST_TMP/$PROG"
    printf '#!/usr/bin/env bash\nsleep 5\n' > "$fake"
    chmod +x "$fake"
    "$fake" __run__ &
    fake_pid=$!
    sleep 0.3
    echo "$fake_pid" > "$PID_FILE"
    run monitor_pid
    [ "$status" -eq 0 ]
    [ "$output" = "$fake_pid" ]
    kill "$fake_pid" 2>/dev/null
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

