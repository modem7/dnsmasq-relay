#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/relay-config.sh"

if [ "$#" -gt 0 ]; then
    exec dnsmasq "$@"
fi

if [ -z "${DHCP_RELAYS:-}" ]; then
    echo "dnsmasq-relay: DHCP_RELAYS is not set and no command was given." >&2
    echo "Set DHCP_RELAYS (see README for syntax), or pass dnsmasq flags directly as the container command." >&2
    exit 1
fi

relay_flags=$(parse_dhcp_relays "$DHCP_RELAYS") || exit 1

# parse_dhcp_relays emits one flag per line; split only on newlines here
# (not the default IFS, which also splits on spaces/tabs) so each line
# stays one argv word even if a future field's content ever contained
# whitespace. This is defense in depth alongside lib/relay-config.sh's
# own field validation, not a substitute for it.
nl='
'
old_ifs="$IFS"

IFS="$nl"
echo "dnsmasq-relay: parsed relay configuration:" >&2
for flag in $relay_flags; do
    describe_relay_flag "$flag" >&2
done
IFS="$old_ifs"

set -- --no-daemon --port=0 --log-facility=-
IFS="$nl"
for flag in $relay_flags; do
    set -- "$@" "$flag"
done
IFS="$old_ifs"

if [ "${DHCP_RELAY_VERBOSE:-0}" = "1" ]; then
    set -- "$@" --log-dhcp
fi

# Intentional word-splitting: DHCP_RELAY_EXTRA_ARGS is a space-separated list.
# shellcheck disable=SC2086
exec dnsmasq "$@" ${DHCP_RELAY_EXTRA_ARGS:-}
