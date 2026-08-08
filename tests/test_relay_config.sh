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

out=$(parse_dhcp_relays "10.0.10.1,10.0.0.5")
assert_eq "single v4 pair produces one flag" "--dhcp-relay=10.0.10.1,10.0.0.5" "$out"

out=$(parse_dhcp_relays "10.0.10.1,10.0.0.5;10.0.20.1,10.0.0.5,eth0")
expected="--dhcp-relay=10.0.10.1,10.0.0.5
--dhcp-relay=10.0.20.1,10.0.0.5,eth0"
assert_eq "multiple pairs each become a flag" "$expected" "$out"

out=$(parse_dhcp_relays "10.0.10.1,10.0.0.5;fd00::1,fd00::5")
expected="--dhcp-relay=10.0.10.1,10.0.0.5
--dhcp-relay=fd00::1,fd00::5"
assert_eq "mixed v4/v6 pairs both parse" "$expected" "$out"

out=$(parse_dhcp_relays "10.0.10.1,10.0.0.5#6700")
assert_eq "server #port suffix preserved" "--dhcp-relay=10.0.10.1,10.0.0.5#6700" "$out"

set +e; err=$(parse_dhcp_relays "" 2>&1 1>/dev/null); s=$?; set -e
assert_status "empty DHCP_RELAYS fails" 1 "$s"
assert_eq "empty DHCP_RELAYS error message" "DHCP_RELAYS is empty" "$err"

set +e; err=$(parse_dhcp_relays "10.0.x.1,10.0.0.5" 2>&1 1>/dev/null); s=$?; set -e
assert_status "malformed local IP fails" 1 "$s"
assert_eq "malformed local IP error message" "DHCP_RELAYS pair 1: '10.0.x.1' is not a valid IP" "$err"

set +e; err=$(parse_dhcp_relays "10.0.10.1" 2>&1 1>/dev/null); s=$?; set -e
assert_status "single-field pair fails" 1 "$s"
assert_eq "single-field pair error message" "DHCP_RELAYS pair 1: expected 2 or 3 comma-separated fields, got 1" "$err"

# Regression: an iface field containing a space must be rejected, not
# silently accepted and later split into a separate dnsmasq argument by
# the consumer's word-splitting (see entrypoint.sh).
set +e; err=$(parse_dhcp_relays "10.0.10.1,10.0.0.5,eth0 --user=root" 2>&1 1>/dev/null); s=$?; set -e
assert_status "iface with embedded space fails" 1 "$s"
assert_eq "iface with embedded space error message" "DHCP_RELAYS pair 1: 'eth0 --user=root' is not a valid interface name" "$err"

set +e; err=$(parse_dhcp_relays "10.0.10.1,10.0.0.5,eth0=bad" 2>&1 1>/dev/null); s=$?; set -e
assert_status "iface with disallowed character fails" 1 "$s"
assert_eq "iface with disallowed character error message" "DHCP_RELAYS pair 1: 'eth0=bad' is not a valid interface name" "$err"

out=$(parse_dhcp_relays "10.0.10.1,10.0.0.5,eth0.10")
assert_eq "iface with dot (VLAN sub-interface name) is accepted" "--dhcp-relay=10.0.10.1,10.0.0.5,eth0.10" "$out"

out=$(describe_relay_flag "--dhcp-relay=10.0.10.1,10.0.0.5")
assert_eq "describe_relay_flag formats v4 summary" "Relaying: 10.0.10.1 -> 10.0.0.5 (v4)" "$out"

out=$(describe_relay_flag "--dhcp-relay=fd00::1,fd00::5")
assert_eq "describe_relay_flag formats v6 summary" "Relaying: fd00::1 -> fd00::5 (v6)" "$out"

echo ""
echo "Passed: $pass, Failed: $fail"
[ "$fail" -eq 0 ]
