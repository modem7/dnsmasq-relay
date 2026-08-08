#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/../lib/relay-config.sh"

pass=0
fail=0

assert_status() {
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected exit: %s\n  actual exit:   %s\n' "$desc" "$expected" "$actual" >&2
    fi
}

assert_eq() {
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
    fi
}

is_valid_ipv4 "10.0.10.1"; assert_status "is_valid_ipv4 accepts 10.0.10.1" 0 $?
is_valid_ipv4 "255.255.255.255"; assert_status "is_valid_ipv4 accepts 255.255.255.255" 0 $?
set +e; is_valid_ipv4 "10.0.10.256"; s=$?; set -e
assert_status "is_valid_ipv4 rejects octet >255" 1 "$s"
set +e; is_valid_ipv4 "10.0.10"; s=$?; set -e
assert_status "is_valid_ipv4 rejects too few octets" 1 "$s"
set +e; is_valid_ipv4 "10.0.x.1"; s=$?; set -e
assert_status "is_valid_ipv4 rejects non-numeric octet" 1 "$s"

is_valid_ipv6 "fd00::1"; assert_status "is_valid_ipv6 accepts fd00::1" 0 $?
set +e; is_valid_ipv6 "10.0.10.1"; s=$?; set -e
assert_status "is_valid_ipv6 rejects v4 literal" 1 "$s"
set +e; is_valid_ipv6 "not-an-ip"; s=$?; set -e
assert_status "is_valid_ipv6 rejects garbage" 1 "$s"

is_valid_ip "10.0.10.1"; assert_status "is_valid_ip accepts v4" 0 $?
is_valid_ip "fd00::1"; assert_status "is_valid_ip accepts v6" 0 $?
set +e; is_valid_ip "garbage"; s=$?; set -e
assert_status "is_valid_ip rejects garbage" 1 "$s"

assert_eq "ip_family v4" "v4" "$(ip_family "10.0.10.1")"
assert_eq "ip_family v6" "v6" "$(ip_family "fd00::1")"

echo ""
echo "Passed: $pass, Failed: $fail"
[ "$fail" -eq 0 ]
