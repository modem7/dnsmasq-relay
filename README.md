# dnsmasq-relay

![Docker Pulls](https://img.shields.io/docker/pulls/modem7/dnsmasq-relay)
![Docker Image Size (tag)](https://img.shields.io/docker/image-size/modem7/dnsmasq-relay/latest)
[![status-badge](https://woodpecker.modem7.com/api/badges/11/status.svg?events=push%2Cmanual)](https://woodpecker.modem7.com/repos/11)
[![Lint Dockerfile](https://github.com/modem7/dnsmasq-relay/actions/workflows/lint.yml/badge.svg)](https://github.com/modem7/dnsmasq-relay/actions/workflows/lint.yml)
[![GitHub latest commit](https://badgen.net/github/last-commit/modem7/dnsmasq-relay)](https://GitHub.com/modem7/dnsmasq-relay/commit/)

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/modem7)

DHCP relay across VLANs and subnets, for routers or switches that don't have a built-in relay function (unlike, for example, Ubiquiti/UniFi gear, which does).

## What this does

This image relays DHCPv4 and DHCPv6 broadcast/multicast traffic between VLANs using [dnsmasq](https://www.thekelleys.org.uk/dnsmasq/doc.html)'s `--dhcp-relay` mode. It replaces [modem7/DHCP-Relay](https://github.com/modem7/DHCP-Relay), which wrapped ISC's `dhcrelay` - upstream ISC-DHCP has had no releases since 2022 and is EOL.

The original plan was to move to [Kea](https://www.isc.org/kea/), ISC's supported DHCP successor, but Kea turned out to have no relay agent of its own - it's server-only. `dnsmasq`'s `--dhcp-relay` mode is actively maintained upstream and purpose-built for exactly this, so it's used here instead.

This image is relay-only: it never runs as a DNS server, DHCP server, or TFTP server, regardless of configuration.

## Prerequisites

dnsmasq's relay identifies which VLAN a request arrived on **by an IP address already assigned to a host interface** - not by interface name. Before configuring `DHCP_RELAYS` (below), each VLAN you want to relay from needs its own IP already set up on the host, for example via a tagged VLAN sub-interface.

netplan example (`/etc/netplan/vlans.yaml`):

```yaml
network:
  version: 2
  vlans:
    vlan10:
      id: 10
      link: eth0
      addresses: [10.0.10.1/24]
    vlan20:
      id: 20
      link: eth0
      addresses: [10.0.20.1/24]
```

systemd-networkd example (`/etc/systemd/network/10-vlan10.netdev` + `/etc/systemd/network/10-vlan10.network`):

```ini
# 10-vlan10.netdev
[NetDev]
Name=vlan10
Kind=vlan

[VLAN]
Id=10
```

```ini
# 10-vlan10.network
[Match]
Name=vlan10

[Network]
Address=10.0.10.1/24
```

If you're relaying DHCPv6 **without** `network_mode: host` (see Quick start, below), read [Docker's IPv6 documentation](https://docs.docker.com/engine/daemon/ipv6/) first - Docker's own virtual networking has IPv6 support disabled by default, separately from anything this image does. Host networking (the default in the compose example below) bypasses Docker's virtual networking entirely, sidestepping this.

## Configuration

| Variable | Required | Description |
|---|---|---|
| `DHCP_RELAYS` | Yes, unless passing raw dnsmasq flags as the container command | Semicolon-separated list of relay pairs: `<local-ip>,<server-ip>[#port][,iface];...`. `local-ip` must already be assigned to a host interface (see Prerequisites). `iface`, if given, is an anti-spoofing filter controlling which interface *replies* are accepted on - not a second relay-side interface. |
| `DHCP_RELAY_EXTRA_ARGS` | No | Space-separated raw dnsmasq flags, appended as-is. Escape hatch for anything `DHCP_RELAYS`' syntax doesn't cover. |
| `DHCP_RELAY_VERBOSE` | No | Set to `1` to add dnsmasq's `--log-dhcp`, logging every relayed DHCP transaction. Start here when troubleshooting "DHCP isn't crossing this VLAN." |

Examples:

```
# Single VLAN relayed to one DHCP server
DHCP_RELAYS="10.0.10.1,10.0.0.5"

# Three VLANs, all relayed to the same server
DHCP_RELAYS="10.0.10.1,10.0.0.5;10.0.20.1,10.0.0.5;10.0.30.1,10.0.0.5"

# Mixed v4 and v6 in the same container
DHCP_RELAYS="10.0.10.1,10.0.0.5;fd00:10::1,fd00::5"
```

If the container is given an explicit command instead (e.g. via compose's `command:`), it's `exec`'d unchanged - `DHCP_RELAYS` and the other env vars are ignored in that case.

## Quick start

```bash
docker run -d \
  --network host \
  --cap-drop ALL --cap-add NET_BIND_SERVICE --cap-add NET_ADMIN --cap-add NET_RAW \
  -e DHCP_RELAYS="10.0.10.1,10.0.0.5;10.0.20.1,10.0.0.5" \
  modem7/dnsmasq-relay:latest
```

Or with compose (see [docker-compose.yml](docker-compose.yml) in this repo):

```yaml
services:
  dnsmasq-relay:
    image: modem7/dnsmasq-relay:latest
    container_name: dnsmasq-relay
    environment:
      DHCP_RELAYS: "10.0.10.1,10.0.0.5;10.0.20.1,10.0.0.5;10.0.30.1,10.0.0.5"
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - NET_ADMIN
      - NET_RAW
    network_mode: host
    restart: always
    mem_limit: 20m
    mem_reservation: 5m
```

## Security notes

The container runs as a non-root user (the `dnsmasq` Alpine package's own system user) with exactly three capabilities, verified empirically by starting the container with `--cap-drop ALL` and adding capabilities back one at a time until dnsmasq stopped reporting a missing one:

- `NET_BIND_SERVICE` - DHCP relay listens on ports 67/547, which are privileged (<1024).
- `NET_ADMIN` - required by dnsmasq's relay path specifically.
- `NET_RAW` - needed to reply to clients that don't have an IP yet.

This is one more capability than the old `dhcrelay`-based image needed (`NET_RAW` + `NET_BIND_SERVICE` only) - `NET_ADMIN` isn't a broader grant than necessary, it's just what dnsmasq's relay implementation actually requires.

## Health checking & troubleshooting

The container's `HEALTHCHECK` is process-liveness based (confirms `dnsmasq` is still PID 1's process). If DHCP requests aren't reaching the far side of a relay, set `DHCP_RELAY_VERBOSE=1` first - it logs every relayed DHCP transaction via `docker logs`, which is almost always enough to see where the conversation is breaking down. Also check the startup log line: the container prints a plain-English summary of what it parsed from `DHCP_RELAYS` (e.g. `Relaying: 10.0.10.1 -> 10.0.0.5 (v4)`) before starting dnsmasq, confirming the config was understood as intended.

## Image tags

Tags track dnsmasq's actual packaged version (e.g. `2.92`), not a build counter, so you can tell at a glance what's inside.

## Licence

[MIT](LICENCE.txt)
