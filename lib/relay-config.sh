#!/bin/sh
# Pure parsing/validation functions for DHCP_RELAYS. No side effects,
# no dnsmasq exec - sourced by entrypoint.sh and by tests/test_relay_config.sh.

is_valid_ipv4() {
    ip="$1"
    case "$ip" in
        ''|*[!0-9.]*) return 1 ;;
    esac

    old_ifs="$IFS"
    IFS='.'
    set -- $ip
    IFS="$old_ifs"

    [ "$#" -eq 4 ] || return 1

    for o in "$1" "$2" "$3" "$4"; do
        case "$o" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$o" -le 255 ] || return 1
    done

    return 0
}

is_valid_ipv6() {
    ip="$1"
    case "$ip" in
        *:*:*) ;;
        *) return 1 ;;
    esac
    case "$ip" in
        *[!0-9a-fA-F:]*) return 1 ;;
    esac
    return 0
}

is_valid_ip() {
    is_valid_ipv4 "$1" || is_valid_ipv6 "$1"
}

ip_family() {
    case "$1" in
        *:*) echo "v6" ;;
        *) echo "v4" ;;
    esac
}

# parse_dhcp_relays <DHCP_RELAYS value>
# On success: prints one "--dhcp-relay=..." line per pair to stdout, returns 0.
# On failure: prints a specific error for the first bad pair to stderr, returns 1.
parse_dhcp_relays() {
    raw="$1"
    if [ -z "$raw" ]; then
        echo "DHCP_RELAYS is empty" >&2
        return 1
    fi

    old_ifs="$IFS"
    IFS=';'
    set -- $raw
    IFS="$old_ifs"

    n=0
    for pair in "$@"; do
        n=$((n + 1))
        [ -z "$pair" ] && continue

        field_count=$(printf '%s' "$pair" | awk -F, '{print NF}')
        local_ip=$(printf '%s' "$pair" | cut -d, -f1)
        server=$(printf '%s' "$pair" | cut -d, -f2)

        case "$field_count" in
            2) iface="" ;;
            3) iface=$(printf '%s' "$pair" | cut -d, -f3) ;;
            *)
                echo "DHCP_RELAYS pair $n: expected 2 or 3 comma-separated fields, got $field_count" >&2
                return 1
                ;;
        esac

        if [ -z "$local_ip" ] || ! is_valid_ip "$local_ip"; then
            echo "DHCP_RELAYS pair $n: '$local_ip' is not a valid IP" >&2
            return 1
        fi

        server_ip="${server%%#*}"
        if [ -z "$server_ip" ] || ! is_valid_ip "$server_ip"; then
            echo "DHCP_RELAYS pair $n: '$server' is not a valid server address" >&2
            return 1
        fi

        if [ -n "$iface" ]; then
            printf '%s\n' "--dhcp-relay=${local_ip},${server},${iface}"
        else
            printf '%s\n' "--dhcp-relay=${local_ip},${server}"
        fi
    done
}

# describe_relay_flag <--dhcp-relay=local,server[,iface]>
# Prints a human-readable one-line summary, e.g.:
#   Relaying: 10.0.10.1 -> 10.0.0.5 (v4)
describe_relay_flag() {
    flag="${1#--dhcp-relay=}"
    local_ip=$(printf '%s' "$flag" | cut -d, -f1)
    server=$(printf '%s' "$flag" | cut -d, -f2)
    family=$(ip_family "$local_ip")
    printf 'Relaying: %s -> %s (%s)\n' "$local_ip" "$server" "$family"
}
