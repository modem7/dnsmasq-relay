#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$SCRIPT_DIR/fixtures/bin:$PATH"

pass=0
fail=0

assert_eq() {
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected:\n%s\n  actual:\n%s\n' "$desc" "$expected" "$actual" >&2
    fi
}

assert_status() {
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected exit: %s\n  actual exit:   %s\n' "$desc" "$expected" "$actual" >&2
    fi
}

out=$(DHCP_RELAYS="10.0.10.1,10.0.0.5" "$REPO_ROOT/entrypoint.sh" 2>/dev/null)
expected="--no-daemon
--port=0
--log-facility=-
--dhcp-relay=10.0.10.1,10.0.0.5"
assert_eq "single pair builds expected dnsmasq argv" "$expected" "$out"

out=$(DHCP_RELAYS="10.0.10.1,10.0.0.5;10.0.20.1,10.0.0.5,eth0" "$REPO_ROOT/entrypoint.sh" 2>/dev/null)
expected="--no-daemon
--port=0
--log-facility=-
--dhcp-relay=10.0.10.1,10.0.0.5
--dhcp-relay=10.0.20.1,10.0.0.5,eth0"
assert_eq "multiple pairs each become a flag" "$expected" "$out"

out=$(DHCP_RELAYS="10.0.10.1,10.0.0.5" DHCP_RELAY_VERBOSE=1 "$REPO_ROOT/entrypoint.sh" 2>/dev/null)
expected="--no-daemon
--port=0
--log-facility=-
--dhcp-relay=10.0.10.1,10.0.0.5
--log-dhcp"
assert_eq "DHCP_RELAY_VERBOSE=1 appends --log-dhcp" "$expected" "$out"

out=$(DHCP_RELAYS="10.0.10.1,10.0.0.5" DHCP_RELAY_EXTRA_ARGS="--dhcp-proxy --bind-interfaces" "$REPO_ROOT/entrypoint.sh" 2>/dev/null)
expected="--no-daemon
--port=0
--log-facility=-
--dhcp-relay=10.0.10.1,10.0.0.5
--dhcp-proxy
--bind-interfaces"
assert_eq "DHCP_RELAY_EXTRA_ARGS words appended" "$expected" "$out"

out=$("$REPO_ROOT/entrypoint.sh" --test --conf-file=/dev/null 2>/dev/null)
expected="--test
--conf-file=/dev/null"
assert_eq "explicit command passes through unchanged" "$expected" "$out"

set +e
err=$(unset DHCP_RELAYS; "$REPO_ROOT/entrypoint.sh" 2>&1 1>/dev/null)
s=$?
set -e
assert_status "missing DHCP_RELAYS and no command exits 1" 1 "$s"
case "$err" in
    *"DHCP_RELAYS is not set"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); printf 'FAIL: missing DHCP_RELAYS error message\n  actual: %s\n' "$err" >&2 ;;
esac

set +e
out=$(DHCP_RELAYS="not-an-ip,10.0.0.5" "$REPO_ROOT/entrypoint.sh" 2>/dev/null)
s=$?
set -e
assert_status "invalid DHCP_RELAYS exits 1" 1 "$s"
assert_eq "invalid DHCP_RELAYS never reaches dnsmasq stub" "" "$out"

echo ""
echo "Passed: $pass, Failed: $fail"
[ "$fail" -eq 0 ]
