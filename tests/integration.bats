#!/usr/bin/env bats

# Integration-style tests use disposable fake external commands. They exercise
# process, file, and secret-store boundaries without touching /etc or a real VPN.

setup() {
    VPNCTL="${BATS_TEST_DIRNAME}/../bin/vpnctl"
    HELPER="${BATS_TEST_DIRNAME}/../libexec/vpnctl-helper"
    TEST_TMP="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/vpnctl-integration.XXXXXX")"
    export VPNCLI_CONFIG_DIR="$TEST_TMP/config"
    export VPNCLI_STATE_DIR="$TEST_TMP/state"
    export SECRET_DB="$TEST_TMP/secret"
    mkdir -p "$VPNCLI_CONFIG_DIR" "$VPNCLI_STATE_DIR"
    # shellcheck disable=SC1090
    source "$VPNCTL"
    SECRET_BACKEND_RESOLVED=secret-tool
    SECRET_SERVICE=integration
}

teardown() {
    if [ -n "${VPN_PID:-}" ] && kill -0 "$VPN_PID" 2>/dev/null; then
        "$HELPER" stop "${VPN_BINARY:-}" "${VPN_CONFIG:-}" "$VPN_PID_FILE" >/dev/null 2>&1 || true
        kill "$VPN_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_TMP"
}

@test "secret store set/get/delete uses backend-scoped accounts" {
    fake_bin="$TEST_TMP/secret-tool"
    cat > "$fake_bin" <<'EOF'
#!/usr/bin/env bash
set -u
db="$SECRET_DB"
case "${1:-}" in
    store)
        value="$(cat)"
        printf '%s' "$value" > "$db"
        ;;
    lookup)
        [ -f "$db" ] && cat "$db"
        ;;
    clear)
        rm -f "$db"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$fake_bin"
    export PATH="$TEST_TMP:$PATH"

    secret_set "test-password"
    [ "$(secret_get password)" = "test-password" ]
    secret_delete password
    ! secret_present password
}

@test "helper starts, identifies, and stops a VPN process" {
    fake_vpn="$TEST_TMP/fake-openvpn"
    config="$TEST_TMP/client.ovpn"
    auth="$TEST_TMP/auth"
    VPN_PID_FILE="$TEST_TMP/vpn.pid"
    VPN_BINARY="$fake_vpn"
    VPN_CONFIG="$config"
    printf '# fake config\n' > "$config"
    printf 'user\npassword\n' > "$auth"
    cat > "$fake_vpn" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
    chmod +x "$fake_vpn"

    "$HELPER" start-openvpn "$fake_vpn" "$config" "$auth" "$VPN_PID_FILE" &
    helper_pid=$!
    for _ in 1 2 3 4 5; do
        [ -s "$VPN_PID_FILE" ] && break
        sleep 0.1
    done
    [ -s "$VPN_PID_FILE" ]
    VPN_PID="$(cat "$VPN_PID_FILE")"
    "$HELPER" status "$fake_vpn" "$config" "$VPN_PID_FILE"
    "$HELPER" stop "$fake_vpn" "$config" "$VPN_PID_FILE"
    wait "$helper_pid" 2>/dev/null || true
    ! kill -0 "$VPN_PID" 2>/dev/null
    [ ! -e "$VPN_PID_FILE" ]
}

@test "helper rejects malformed pid files without executing kill" {
    pid_file="$TEST_TMP/bad.pid"
    fake_vpn="$TEST_TMP/fake-openvpn"
    config="$TEST_TMP/client.ovpn"
    printf '# fake config\n' > "$config"
    printf 'not-a-pid\n' > "$pid_file"
    run "$HELPER" stop "$fake_vpn" "$config" "$pid_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid pid file"* ]]
    [ -e "$pid_file" ]
}

@test "helper refuses to stop a process with a mismatched identity" {
    config="$TEST_TMP/client.ovpn"
    pid_file="$TEST_TMP/vpn.pid"
    VPN_PID_FILE="$pid_file"
    VPN_BINARY="$TEST_TMP/not-the-vpn"
    VPN_CONFIG="$config"
    printf '# fake config\n' > "$config"
    sleep 30 &
    VPN_PID="$!"
    printf '%s\n' "$VPN_PID" > "$pid_file"

    run "$HELPER" stop "$TEST_TMP/not-the-vpn" "$config" "$pid_file"
    [ "$status" -ne 0 ]
    kill -0 "$VPN_PID"
    [ -e "$pid_file" ]
}

@test "privileged helper stop refuses a stale PID reused by another process" {
    command -v sudo >/dev/null 2>&1 || skip "sudo not available"
    run sudo -n true
    [ "$status" -eq 0 ] || skip "passwordless sudo not available"

    fake_vpn="$TEST_TMP/fake-openvpn"
    config="$TEST_TMP/client.ovpn"
    pid_file="$TEST_TMP/vpn.pid"
    printf '# fake config\n' > "$config"
    sleep 30 &
    VPN_PID="$!"
    printf '%s\n' "$VPN_PID" > "$pid_file"
    run sudo -n "$HELPER" stop "$fake_vpn" "$config" "$pid_file"
    [ "$status" -ne 0 ]
    kill -0 "$VPN_PID"
    [ -e "$pid_file" ]
    kill "$VPN_PID"
}

@test "sudoers renderer and visudo validate a disposable rule" {
    command -v visudo >/dev/null 2>&1 || skip "visudo not available"
    template="$TEST_TMP/template"
    output="$TEST_TMP/rule"
    printf '%s\n' 'alice ALL=(root) NOPASSWD: /usr/bin/true -c /tmp/a\=b\*c' > "$template"
    render_template "$template" > "$output"
    run visudo -cf "$output"
    [ "$status" -eq 0 ]
}
