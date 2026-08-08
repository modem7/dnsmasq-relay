# dnsmasq-relay design

## Background

`modem7/DHCP-Relay` wraps ISC's `dhcrelay` (from the `isc-dhcp` suite), which
has had no upstream releases since 2022 and lost its Alpine package entirely
as of 3.21. DHCP-Relay is now in maintenance mode (Debian security patches
only). The original plan was to replace it with a Kea-based image, but
research during this design pass found that **Kea has no relay agent of its
own** — confirmed via `apt-cache search kea` (no relay package exists),
Kea's own ARM documentation (which only describes how the *server* processes
packets that arrive from an external relay), and independent confirmation
that ISC discontinued `isc-dhcp-relay` by Q2 2022 with no in-house
replacement. Kea is server-only; it was ruled out for this project.

The actual need — clarified directly by the user — is unchanged from
DHCP-Relay's: **relay DHCP broadcast traffic across VLANs/subnets on
routers or switches that lack a built-in relay function** (contrasted with
e.g. Ubiquiti/UniFi gear, which has one built in). What changes is the
underlying tool: `dnsmasq`'s `--dhcp-relay` mode is actively maintained
upstream (unlike `dhcrelay`) and is purpose-built for exactly this.

**Repo name**: `modem7/dnsmasq-relay` (not `kea-dhcp-relay` — Kea isn't
involved; not `dhcp-relay` — that collides case-insensitively with the
existing `modem7/DHCP-Relay` on GitHub, confirmed via `gh repo view
modem7/dhcp-relay` resolving to the existing repo).

## Goals

- Relay DHCPv4 and DHCPv6 broadcast/multicast traffic between VLANs, using
  `dnsmasq --dhcp-relay`.
- Support multiple simultaneous relay pairs in a single container instance
  (dnsmasq natively supports repeating `--dhcp-relay=` for this; the old
  DHCP-Relay image only ever exposed one down/up interface pair per
  container).
- Non-root, minimal-capability container, matching DHCP-Relay's
  empirically-verified security posture.
- Fit the existing `modem7` org's repo/CI conventions (renovate, GitHub
  Actions lint, Woodpecker build/publish, README badge conventions).

## Non-goals

- Not a DHCP server. No lease management, no `--dhcp-range`, no DNS, no
  TFTP — these are explicitly disabled so the image can't accidentally run
  as anything but a relay.
- Not a Kea-based image (Kea has no relay function; see Background).
- No automatic host network/VLAN interface provisioning from inside the
  container (would require `NET_ADMIN`-driven interface creation from
  inside Docker, which works against the least-privilege posture — see
  "Capabilities" below. Provisioning host VLAN interfaces stays the host's
  job, not the container's).

## Architecture

- **Base image**: `alpine:3.24` (pinned tag; Renovate bumps via its
  default docker manager — no `ARG ALPINE_VERSION`/s6-overlay pattern,
  since this runs a single foreground process, unlike `docker-borgmatic`'s
  multi-process s6 setup).
- **Package**: Alpine's `dnsmasq` (2.92 at time of writing), compiled with
  `DHCP` and `DHCPv6` support (verified via `dnsmasq --version`). The
  `dnsmasq` Alpine package creates its own system user/group (`dnsmasq`),
  reused directly rather than inventing a new uid/gid.
- **Networking**: `network_mode: host` by default (documented in the
  compose example), matching DHCP-Relay's precedent. dnsmasq's relay
  matches incoming traffic by an IP address already assigned to a host
  interface (see "Config interface" below), not by interface name, so the
  container needs to see the host's real VLAN-tagged interfaces directly.
  README documents [Docker's IPv6 daemon
  docs](https://docs.docker.com/engine/daemon/ipv6/) as required reading
  for anyone who runs this *without* host networking and relays DHCPv6,
  since host mode bypasses Docker's own virtual networking (and therefore
  its IPv6 opt-in) entirely.
- **Entrypoint**: POSIX shell script, no templating/runtime dependency.
  Parses `DHCP_RELAYS` into repeated `--dhcp-relay=` flags and `exec`s
  `dnsmasq` directly as PID 1 (`--no-daemon`), mirroring DHCP-Relay's
  `entrypoint.sh` minimalism.

## Config interface

One primary env var drives the whole image:

```
DHCP_RELAYS="<local-ip>,<server-ip>[#port],[iface];<local-ip>,<server-ip>[#port],[iface];..."
```

- Semicolon-separated relay pairs. Each pair's comma-separated fields map
  1:1 onto dnsmasq's own flag syntax:
  `--dhcp-relay=<local address>[,<server address>[#<port>]][,<interface>]`
  (verified against the real `dnsmasq.8` man page shipped in Alpine's
  package, not assumed).
- `local-ip` **must already be assigned to a host interface** — this is
  how dnsmasq identifies which VLAN a request arrived on. It is not an
  interface name.
- `server-ip` is the DHCP server's address the request gets relayed to.
- The optional third field (`iface`) is an anti-spoofing filter — it
  controls which interface DHCP *replies* are accepted on, not a second
  relay-side interface.
- v4 and v6 pairs may coexist in the same `DHCP_RELAYS` list — dnsmasq
  multiplexes both in one process, so there is no separate mode switch
  like the old image's `DHCRELAY_MODE`.
- `DHCP_RELAY_EXTRA_ARGS` — optional, space-word-split, appended raw to
  the `dnsmasq` command line. Escape hatch for anything the pair syntax
  doesn't cover (mirrors `DHCRELAY_EXTRA_ARGS`).
- `DHCP_RELAY_VERBOSE=1` — optional, adds `--log-dhcp` for per-transaction
  DHCP relay logging. Exposed as a dedicated toggle (rather than requiring
  users to know the raw flag) because "why isn't DHCP crossing this VLAN"
  is expected to be the most common support question for this image.
- Command passthrough — if the container is given an explicit command, it
  is `exec`'d as-is, unchanged (kept for consistency/scriptability with
  DHCP-Relay's convention, even though there's no prior image config to
  migrate here).
- Hard-disabled always, regardless of env vars: `--port=0` (no DNS
  service), no `--dhcp-range` (no DHCP server role), `--log-facility=-`
  (logs to stdout so `docker logs` shows them — dnsmasq defaults to
  syslog, which would otherwise leave the container silent).
- On startup, before `exec`ing dnsmasq, the entrypoint:
  1. Validates `DHCP_RELAYS` is set (if not, and no command/extra-args
     given, exits with a clear usage error, matching DHCP-Relay's
     behavior for missing `DHCRELAY_*` vars).
  2. Parses and sanity-checks each pair (well-formed IP literals, correct
     field count) — a malformed entry produces a specific error (e.g.
     `DHCP_RELAYS pair 2: '10.0.x.1' is not a valid IP`) rather than
     surfacing dnsmasq's own less-specific startup failure.
  3. Prints a plain-English summary of the parsed relay pairs (e.g.
     `Relaying: 10.0.10.1 -> 10.0.0.5 (v4)`) so `docker logs` immediately
     confirms what's configured.

## Capabilities (empirically verified)

Verified directly with a throwaway build (`alpine:3.24` + `dnsmasq` +
`setcap`), not assumed from documentation. dnsmasq performs its own
capability checks and names exactly what's missing:

1. Started with `--cap-drop ALL` as root: dnsmasq reported missing
   `NET_BIND_SERVICE` (ports 67/547 are privileged).
2. Added `NET_BIND_SERVICE`: dnsmasq then reported missing `NET_ADMIN`.
3. Added `NET_ADMIN`: dnsmasq then reported missing `NET_RAW`.
4. Added `NET_RAW`: started cleanly and began relaying
   (`dnsmasq-dhcp: DHCP relay from 127.0.0.1 to 127.0.0.2` in the logs).
5. Re-verified as a non-root user: `apk add dnsmasq libcap`, `setcap
   cap_net_bind_service,cap_net_admin,cap_net_raw+eip /usr/sbin/dnsmasq`,
   `apk del libcap`, then ran as the `dnsmasq` system user with only those
   3 caps in the container's `cap_add` — started cleanly.

Required set: **`NET_BIND_SERVICE` + `NET_ADMIN` + `NET_RAW`** — one more
than `dhcrelay` needed (`NET_RAW` + `NET_BIND_SERVICE` only).
`NET_ADMIN` is specific to dnsmasq's relay path; the README documents this
explicitly so it doesn't read as an oversight or an over-broad grant.

Test image/container removed after verification
(`docker rmi dnsmasq-captest`, scratch Dockerfile deleted); no leftover
artifacts from this testing remain.

## Dockerfile (shape)

```dockerfile
FROM alpine:3.24
LABEL org.opencontainers.image.title="dnsmasq-relay" \
      org.opencontainers.image.description="DHCP relay across VLANs using dnsmasq" \
      org.opencontainers.image.source="https://github.com/modem7/dnsmasq-relay" \
      org.opencontainers.image.licenses="MIT"

# hadolint ignore=DL3018
RUN apk add --no-cache dnsmasq libcap tzdata \
    && setcap cap_net_bind_service,cap_net_admin,cap_net_raw+eip /usr/sbin/dnsmasq \
    && apk del libcap

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER dnsmasq:dnsmasq
EXPOSE 67/udp 547/udp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
    CMD ["sh", "-c", "[ \"$(cat /proc/1/comm)\" = dnsmasq ]"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

`apk add` stays version-unpinned; `.hadolint.yaml` gets a `DL3018`
override with the same rationale as DHCP-Relay's `DL3008` override —
Alpine's own security patching within the pinned `3.24` tag keeps the
package current without hand-pinning a version that would drift stale.

## Repo scaffolding (org conventions)

- `renovate.json`: `{"extends": ["github>modem7/renovate-config"]}` only.
  No `:docker` preset addition — that pattern is for repos pinning
  `ARG ALPINE_VERSION`/`ARG PYTHON_VERSION` with s6-overlay
  (`docker-borgmatic`), which doesn't apply here.
- `.github/settings.yml`: `_extends: .github`, then repo-specific
  `repository:` fields only (description, topics, `default_branch:
  master`, merge settings). No `labels:` block (inherited account-wide).
- `.github/workflows/autoassign.yml`: copied verbatim from
  `docker-devenv`/`.github` — `auto-assign-issue` +
  `auto-assign-pr` (skipped for `renovate[bot]`), both via
  `pozil/auto-assign-issue@v4.0.1`, assignee `modem7`.
- `.github/workflows/lint.yml`: hadolint on GitHub Actions (not
  Woodpecker), digest-pinned image, triggered on push/PR/dispatch scoped
  to `Dockerfile`. Shape copied from `docker-starwars`.
- `.woodpecker.yml`: `event: [push, manual]`, `branch: master`, `path:
  include:` scoped to `Dockerfile`, `entrypoint.sh`. Steps: build/push via
  `woodpeckerci/plugin-docker-buildx`, then `pushrm-dockerhub`
  (`chko/docker-pushrm`), then the `notify-slack` step copied from
  DHCP-Relay's boilerplate. A `prepare-tags` step resolves dnsmasq's
  actual packaged version (e.g. `2.92`) and writes a `.tags` file, so
  image tags track real software versions rather than a build counter.
- No `labelsync.yml`/`labels.yml` (fully replaced by `settings.yml`
  inheritance account-wide).
- `LICENCE.txt` (British spelling, MIT — already committed as the repo's
  bootstrap commit), GB English throughout.

## README sections

1. Title + badges — Docker Pulls, Image Size, GH Actions lint badge,
   last-commit, Buy Me A Coffee now; Woodpecker status badge added once
   the repo is registered there and the user provides the real badge
   URL/repo ID before merge (left as an explicit placeholder until then).
2. What this does — relays DHCP across VLANs/subnets lacking built-in
   relay support (UniFi contrast as a concrete anchor), why this replaces
   DHCP-Relay, and why it isn't Kea-based (linked back to DHCP-Relay's
   README for continuity).
3. Prerequisites — the local-IP-must-already-exist-on-a-host-interface
   requirement, with worked netplan and systemd-networkd VLAN
   sub-interface examples. Links Docker's IPv6 daemon docs as a caveat for
   non-host-networking deployments relaying DHCPv6.
4. Configuration reference — table of env vars (`DHCP_RELAYS` syntax with
   worked single-pair/multi-pair/mixed-v4-v6 examples, `DHCP_RELAY_EXTRA_ARGS`,
   `DHCP_RELAY_VERBOSE`, command passthrough).
5. Quick start — `docker run` one-liner and a full `docker-compose.yml`
   (`network_mode: host`, `cap_drop: [ALL]`, `cap_add: [NET_BIND_SERVICE,
   NET_ADMIN, NET_RAW]`, `mem_limit`/`mem_reservation`, a realistic
   2-3-VLAN `DHCP_RELAYS` example).
6. Security notes — non-root user, the 3 capabilities and why each is
   needed, contrasted with `dhcrelay`'s 2-capability requirement so the
   extra `NET_ADMIN` doesn't read as a mistake.
7. Health checking & troubleshooting — process-liveness `HEALTHCHECK`
   explained; `DHCP_RELAY_VERBOSE=1` as the first troubleshooting step.
8. Image tags — track dnsmasq's actual version, not a build counter.
9. Licence — link to `LICENCE.txt`, MIT.

## Testing plan (for implementation phase)

- Build the real image; repeat the capability verification above against
  the final Dockerfile (not just the throwaway scratch image) to confirm
  nothing in the real build changes the required cap set.
- Exercise `DHCP_RELAYS` parsing: valid single pair, multiple pairs, mixed
  v4/v6, malformed entries (bad IP, wrong field count, missing var
  entirely) — confirm the entrypoint's validation errors are specific and
  actionable.
- Confirm `docker logs` shows dnsmasq's own log lines (validates
  `--log-facility=-` actually routes to stdout) and the startup summary
  line.
- Confirm the `HEALTHCHECK` passes while dnsmasq runs and fails/reports
  unhealthy if the process is killed.
- hadolint clean (aside from the deliberate `DL3018` override) via the
  GitHub Actions lint workflow.

## Open items carried forward (not blocking this design)

- Woodpecker badge URL/repo ID — user will provide once the repo is
  registered there, before merge.
- Once this repo exists and has real content, update
  `modem7/DHCP-Relay`'s README placeholder link
  (currently `[modem7/kea-dhcp-relay](#) (placeholder...)`) to point at
  `modem7/dnsmasq-relay` instead, and correct the "moving to Kea" wording
  to reflect that Kea was ruled out and dnsmasq was used instead.
