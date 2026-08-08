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
