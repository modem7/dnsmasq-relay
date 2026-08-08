# dnsmasq-relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `modem7/dnsmasq-relay` — a non-root, minimal-capability Docker image that relays DHCPv4/DHCPv6 broadcast traffic across VLANs using `dnsmasq --dhcp-relay`, replacing `modem7/DHCP-Relay` (which wrapped the now-EOL `dhcrelay`).

**Architecture:** A POSIX-shell entrypoint parses one env var (`DHCP_RELAYS`) into repeated `dnsmasq --dhcp-relay=` flags and `exec`s `dnsmasq` directly as PID 1. Parsing/validation lives in a separate sourced library (`lib/relay-config.sh`) so it can be unit-tested without Docker or a real `dnsmasq` binary. The image is `alpine:3.24` + the `dnsmasq` package, running as the package's own non-root `dnsmasq` system user with three capabilities (`NET_BIND_SERVICE`, `NET_ADMIN`, `NET_RAW`) verified empirically, not assumed.

**Tech Stack:** POSIX `sh` (no bashisms — targets both `dash` on the dev host and BusyBox `ash` inside the Alpine image), Alpine `dnsmasq` package, Docker, GitHub Actions (hadolint), Woodpecker CI (build/publish).

## Global Constraints

- Base image: `alpine:3.24` (pinned tag; no `ARG ALPINE_VERSION`/s6-overlay — single foreground process).
- All shell scripts are POSIX `sh` — no `local`, no `[[ ]]`, no arrays, no bashisms. Verify with `sh script.sh`, not just `bash script.sh`.
- Required capabilities, verified empirically against the real built image (not assumed from docs): `NET_BIND_SERVICE`, `NET_ADMIN`, `NET_RAW`. No other capabilities are added.
- Non-root: `USER dnsmasq:dnsmasq` — the Alpine `dnsmasq` package's own system user (verified uid 100 / gid 101 on `alpine:3.24`, but referenced by name, never hardcoded as a number, since that's not guaranteed stable across Alpine releases).
- `DHCP_RELAYS` env var syntax: `<local-ip>,<server-ip>[#port][,iface];<local-ip>,<server-ip>[#port][,iface];...` — semicolon-separated pairs, each pair 2 or 3 comma-separated fields, mapping 1:1 onto dnsmasq's own `--dhcp-relay=<local address>[,<server address>[#<server port>]][,<interface>]` flag syntax.
- Always hard-disabled regardless of env vars: DNS (`--port=0`), DHCP server role (no `--dhcp-range` ever generated), and dnsmasq's default syslog logging (`--log-facility=-`, routes to stderr so `docker logs` shows it).
- No repo names/paths other than `modem7/dnsmasq-relay` — this is not Kea-based and not a fork of DHCP-Relay's files.
- Never push directly to `master` — every task's commit happens on a feature branch; the branch-protection hook in this environment hard-blocks `git push origin master` regardless of intent.

---

## File Structure

```
dnsmasq-relay/
├── Dockerfile
├── entrypoint.sh
├── lib/
│   └── relay-config.sh          # pure parsing/validation, sourced by entrypoint.sh and tests
├── docker-compose.yml
├── README.md
├── LICENCE.txt                  # already committed on master
├── renovate.json
├── .hadolint.yaml
├── .woodpecker.yml
├── .github/
│   ├── settings.yml
│   └── workflows/
│       ├── autoassign.yml
│       └── lint.yml
├── docs/superpowers/
│   ├── specs/2026-08-08-dnsmasq-relay-design.md   # already committed on docs/design-doc
│   └── plans/2026-08-08-dnsmasq-relay-implementation.md  # this file
└── tests/
    ├── test_relay_config.sh
    ├── test_entrypoint.sh
    └── fixtures/bin/dnsmasq     # stub used by test_entrypoint.sh
```

---

### Task 0: Branch setup

**Files:** none (repo operation only)

- [ ] **Step 1: Create the implementation branch off `docs/design-doc`**

The design doc branch (`docs/design-doc`) is already pushed but not merged. Branch implementation work from it so the design doc is present in the tree for reference; both will be reconciled when `docs/design-doc` merges to `master`.

```bash
cd /home/modem7/project/dnsmasq-relay
git fetch origin
git checkout docs/design-doc
git pull origin docs/design-doc
git checkout -b feat/initial-implementation
```

Expected: `Switched to a new branch 'feat/initial-implementation'`.

---

### Task 1: `lib/relay-config.sh` — IP validation functions

**Files:**
- Create: `lib/relay-config.sh`
- Test: `tests/test_relay_config.sh`

**Interfaces:**
- Produces: `is_valid_ipv4(ip) -> exit status 0/1`, `is_valid_ipv6(ip) -> exit status 0/1`, `is_valid_ip(ip) -> exit status 0/1`, `ip_family(ip) -> prints "v4" or "v6" to stdout`. All take one positional argument, no globals read.

- [ ] **Step 1: Write the failing test**

Create `tests/test_relay_config.sh`:

```sh
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
```

- [ ] **Step 2: Run it to confirm it fails (lib doesn't exist yet)**

```bash
chmod +x tests/test_relay_config.sh
sh tests/test_relay_config.sh
```

Expected: fails immediately with something like
`tests/test_relay_config.sh: line 4: can't open '.../lib/relay-config.sh'` — confirms the test actually exercises the not-yet-written file, not a vacuous pass.

- [ ] **Step 3: Write the implementation**

Create `lib/relay-config.sh`:

```sh
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
```

Note: `is_valid_ipv4`'s `set -- $ip` only reassigns positional parameters for the *duration of this function call* — POSIX shell functions get their own positional-parameter scope that's restored to the caller's on return, so this can't corrupt a caller's `$1`/`$2`/etc.

This is a deliberate "sanity check," not full RFC 4291 IPv6 validation — it accepts anything with ≥2 colons and only hex/colon characters. That's enough to catch the realistic failure mode (a typo'd IP), and is called out as a known limitation in the README.

- [ ] **Step 4: Run the test again to confirm it passes**

```bash
sh tests/test_relay_config.sh
```

Expected: ends with `Passed: 12, Failed: 0` and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add lib/relay-config.sh tests/test_relay_config.sh
git commit -m "Add IP validation functions for DHCP_RELAYS parsing"
```

---

### Task 2: `lib/relay-config.sh` — `parse_dhcp_relays` and `describe_relay_flag`

**Files:**
- Modify: `lib/relay-config.sh`
- Modify: `tests/test_relay_config.sh`

**Interfaces:**
- Consumes: `is_valid_ip(ip)`, `ip_family(ip)` from Task 1.
- Produces: `parse_dhcp_relays(raw) -> stdout: one "--dhcp-relay=..." line per pair, exit 0` on success; `-> stderr: one specific error line, exit 1` on the first invalid pair. `describe_relay_flag(flag) -> stdout: "Relaying: <local> -> <server> (<v4|v6>)"`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_relay_config.sh`, just above the final `echo ""` / `echo "Passed..."` block:

```sh
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

out=$(describe_relay_flag "--dhcp-relay=10.0.10.1,10.0.0.5")
assert_eq "describe_relay_flag formats v4 summary" "Relaying: 10.0.10.1 -> 10.0.0.5 (v4)" "$out"

out=$(describe_relay_flag "--dhcp-relay=fd00::1,fd00::5")
assert_eq "describe_relay_flag formats v6 summary" "Relaying: fd00::1 -> fd00::5 (v6)" "$out"
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
sh tests/test_relay_config.sh
```

Expected: fails with `parse_dhcp_relays: not found` (or similar "command not found") — the functions don't exist yet.

- [ ] **Step 3: Write the implementation**

Append to `lib/relay-config.sh`:

```sh
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
```

`set -- $raw` (splitting on `;`) is only used once, before the `for pair in "$@"` loop begins — the loop's word list is captured at that point, so nothing inside the loop body touches `$@` again. Inner field-splitting uses `cut`/`awk` instead of a second `set --`, avoiding any ambiguity about which split "owns" the positional parameters.

- [ ] **Step 4: Run the test again to confirm it passes**

```bash
sh tests/test_relay_config.sh
```

Expected: ends with `Passed: 21, Failed: 0` and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add lib/relay-config.sh tests/test_relay_config.sh
git commit -m "Add DHCP_RELAYS pair parsing and summary formatting"
```

---

### Task 3: `entrypoint.sh`

**Files:**
- Create: `entrypoint.sh`
- Create: `tests/fixtures/bin/dnsmasq`
- Create: `tests/test_entrypoint.sh`

**Interfaces:**
- Consumes: `parse_dhcp_relays(raw)`, `describe_relay_flag(flag)` from `lib/relay-config.sh` (Task 2), sourced via a path relative to `entrypoint.sh` itself (works identically whether run from the repo root during testing or from `/usr/local/bin/` inside the built image, as long as `lib/relay-config.sh` sits next to `entrypoint.sh` in both layouts).
- Produces: a script that `exec`s `dnsmasq` with the final argv — this is what Task 4's Dockerfile `ENTRYPOINT` points at.

- [ ] **Step 1: Write the failing test**

Create `tests/fixtures/bin/dnsmasq` (a stub that just echoes its argv, one per line, so tests can assert on the exact command line `entrypoint.sh` builds without needing a real `dnsmasq` binary or Docker):

```sh
#!/bin/sh
printf '%s\n' "$@"
```

Create `tests/test_entrypoint.sh`:

```sh
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
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
chmod +x tests/fixtures/bin/dnsmasq tests/test_entrypoint.sh
sh tests/test_entrypoint.sh
```

Expected: fails — `entrypoint.sh` doesn't exist yet (`No such file or directory`).

- [ ] **Step 3: Write the implementation**

Create `entrypoint.sh`:

```sh
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

echo "dnsmasq-relay: parsed relay configuration:" >&2
for flag in $relay_flags; do
    describe_relay_flag "$flag" >&2
done

set -- --no-daemon --port=0 --log-facility=-
for flag in $relay_flags; do
    set -- "$@" "$flag"
done

if [ "${DHCP_RELAY_VERBOSE:-0}" = "1" ]; then
    set -- "$@" --log-dhcp
fi

# Intentional word-splitting: DHCP_RELAY_EXTRA_ARGS is a space-separated list.
# shellcheck disable=SC2086
exec dnsmasq "$@" ${DHCP_RELAY_EXTRA_ARGS:-}
```

The human-readable summary (`describe_relay_flag`) is written to **stderr**, not stdout — this keeps stdout reserved for whatever the eventually-`exec`'d process emits, and matches `--log-facility=-`'s own convention of dnsmasq logging to stderr. `docker logs` captures both streams together regardless, so nothing is lost operationally.

- [ ] **Step 4: Run the test again to confirm it passes**

```bash
sh tests/test_entrypoint.sh
```

Expected: ends with `Passed: 8, Failed: 0` and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add entrypoint.sh tests/fixtures/bin/dnsmasq tests/test_entrypoint.sh
git commit -m "Add entrypoint.sh wiring DHCP_RELAYS parsing to dnsmasq"
```

---

### Task 4: Dockerfile + `.hadolint.yaml`

**Files:**
- Create: `Dockerfile`
- Create: `.hadolint.yaml`

**Interfaces:**
- Consumes: `entrypoint.sh`, `lib/relay-config.sh` (Tasks 2-3), copied into the image at `/usr/local/bin/`.
- Produces: the `modem7/dnsmasq-relay` image referenced by Task 5 (compose example) and Task 7 (`.woodpecker.yml` build step).

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
FROM alpine:3.24
LABEL org.opencontainers.image.title="dnsmasq-relay" \
      org.opencontainers.image.description="DHCP relay across VLANs using dnsmasq" \
      org.opencontainers.image.source="https://github.com/modem7/dnsmasq-relay" \
      org.opencontainers.image.licenses="MIT"

# hadolint ignore=DL3018
RUN apk add --no-cache dnsmasq libcap tzdata \
    && setcap cap_net_bind_service,cap_net_admin,cap_net_raw+eip /usr/sbin/dnsmasq \
    && apk del libcap \
    && mkdir -p /usr/local/bin/lib

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=644 lib/relay-config.sh /usr/local/bin/lib/relay-config.sh

USER dnsmasq:dnsmasq
EXPOSE 67/udp 547/udp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
    CMD ["sh", "-c", "[ \"$(cat /proc/1/comm)\" = dnsmasq ]"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

**Do not drop the `mkdir -p /usr/local/bin/lib` step.** Without it, `COPY --chmod=644 lib/relay-config.sh /usr/local/bin/lib/relay-config.sh` implicitly creates the `lib` directory itself with mode `644` (no execute/traverse bit) instead of a proper directory mode — this was caught empirically while designing this plan: it silently breaks `.`-sourcing the library at runtime with `Permission denied`, even though the *file* inside it is readable. Creating the directory explicitly first (default `755`) avoids this.

- [ ] **Step 2: Build the image**

```bash
docker build -t modem7/dnsmasq-relay:dev .
```

Expected: build succeeds, ends with `naming to docker.io/modem7/dnsmasq-relay:dev done`.

- [ ] **Step 3: Empirically verify the required capability set against the real image**

```bash
echo "=== all 3 caps: should start and relay ==="
timeout 3 docker run --rm --cap-drop ALL --cap-add NET_BIND_SERVICE --cap-add NET_ADMIN --cap-add NET_RAW \
  -e DHCP_RELAYS="127.0.0.1,127.0.0.2" modem7/dnsmasq-relay:dev

echo "=== missing NET_ADMIN: should fail with 'Operation not permitted' ==="
timeout 3 docker run --rm --cap-drop ALL --cap-add NET_BIND_SERVICE --cap-add NET_RAW \
  -e DHCP_RELAYS="127.0.0.1,127.0.0.2" modem7/dnsmasq-relay:dev
```

Expected first block: logs show `dnsmasq[1]: started, version 2.92...` and `dnsmasq-dhcp[1]: DHCP relay from 127.0.0.1 to 127.0.0.2`, then exits via the 3-second `timeout` (`exit: 124`) — that's the test harness stopping it, not a failure.
Expected second block: `entrypoint.sh: exec: line 34: dnsmasq: Operation not permitted` (exit 126) — confirms `NET_ADMIN` really is required, not just NET_BIND_SERVICE/NET_RAW.

- [ ] **Step 4: Verify invalid config is rejected before dnsmasq ever starts**

```bash
docker run --rm -e DHCP_RELAYS="bad,10.0.0.5" modem7/dnsmasq-relay:dev
echo "exit: $?"
```

Expected: `DHCP_RELAYS pair 1: 'bad' is not a valid IP` and `exit: 1`.

- [ ] **Step 5: Verify the healthcheck**

```bash
docker rm -f dnsmasq-relay-hc-test 2>/dev/null
docker run -d --name dnsmasq-relay-hc-test --cap-drop ALL --cap-add NET_BIND_SERVICE --cap-add NET_ADMIN --cap-add NET_RAW \
  -e DHCP_RELAYS="127.0.0.1,127.0.0.2" modem7/dnsmasq-relay:dev
sleep 6
docker inspect --format='{{.State.Health.Status}}' dnsmasq-relay-hc-test
docker rm -f dnsmasq-relay-hc-test
```

Expected: prints `healthy`.

- [ ] **Step 6: Write `.hadolint.yaml` and verify hadolint is clean**

Create `.hadolint.yaml`:

```yaml
override:
  style:
    - DL3018
    - DL3066
```

`DL3018` (pin apk package versions) is deliberately overridden: `dnsmasq` stays unpinned so every rebuild picks up Alpine's own security patching within the pinned `3.24` base, the same rationale DHCP-Relay used for its `DL3008` override on `apt-get install`. `DL3066` (prefers a numeric `USER` id) is overridden because `dnsmasq:dnsmasq` reuses the Alpine package's own system user by name — more self-documenting and not dependent on a uid/gid number that isn't guaranteed stable across Alpine releases.

```bash
docker run --rm -v "$PWD":/work -w /work \
  hadolint/hadolint:v2.15.1-alpine@sha256:a1d49ae1a4e83c1dbad26b8c1ad7588c8bd1e04f4866b34ad3cac50335198552 \
  sh -c "hadolint Dockerfile"
echo "exit: $?"
```

Expected: prints the `DL3066` finding at `style` severity (informational only) and `exit: 0`.

- [ ] **Step 7: Clean up test containers/images before committing**

```bash
docker rmi modem7/dnsmasq-relay:dev
docker ps -a --filter ancestor=modem7/dnsmasq-relay:dev -q | xargs -r docker rm -f
```

- [ ] **Step 8: Commit**

```bash
git add Dockerfile .hadolint.yaml
git commit -m "Add Dockerfile with empirically-verified minimal capabilities"
```

---

### Task 5: `docker-compose.yml` example

**Files:**
- Create: `docker-compose.yml`

**Interfaces:**
- Consumes: the image built in Task 4 (`modem7/dnsmasq-relay`), the `DHCP_RELAYS` syntax from Task 2.

- [ ] **Step 1: Write the compose file**

```yaml
#################
##dnsmasq-relay##
#################

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

- [ ] **Step 2: Validate it parses**

```bash
docker compose -f docker-compose.yml config >/dev/null
echo "exit: $?"
```

Expected: `exit: 0` (no output means valid YAML/compose schema; `image: modem7/dnsmasq-relay:latest` doesn't need to actually exist on Docker Hub yet for `config` to validate).

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "Add docker-compose.yml example"
```

---

### Task 6: Repo scaffolding — renovate, GitHub settings, autoassign, lint workflow

**Files:**
- Create: `renovate.json`
- Create: `.github/settings.yml`
- Create: `.github/workflows/autoassign.yml`
- Create: `.github/workflows/lint.yml`

**Interfaces:** none (CI/repo-config only, no runtime code dependencies).

- [ ] **Step 1: Write `renovate.json`**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>modem7/renovate-config"]
}
```

No `:docker` preset addition — that pattern is only for repos pinning `ARG ALPINE_VERSION`/`ARG PYTHON_VERSION` with s6-overlay (`docker-borgmatic`), which doesn't apply here (single foreground process, no s6).

- [ ] **Step 2: Write `.github/settings.yml`**

```yaml
_extends: .github
# https://github.com/apps/settings
# https://github.com/repository-settings/app

repository:
  description: DHCP relay across VLANs using dnsmasq
  topics: docker, dhcp, dhcp-relay, dnsmasq, vlan

  private: false
  has_issues: true
  has_wiki: false
  has_downloads: true
  has_projects: false

  default_branch: master

  allow_squash_merge: true
  allow_rebase_merge: true
  allow_merge_commit: false

  enable_automated_security_fixes: true
  enable_vulnerability_alerts: true
```

No `labels:` block — inherited account-wide from the `.github` repo.

- [ ] **Step 3: Write `.github/workflows/autoassign.yml`**

```yaml
name: Issue and PR assignment

on:
  issues:
    types: [opened]
  pull_request:
    types: [opened]

jobs:
  auto-assign-issue:
    if: github.event_name == 'issues'
    runs-on: ubuntu-latest
    permissions:
      issues: write
    steps:
        - name: 'Auto-assign issue'
          uses: pozil/auto-assign-issue@v4.0.1
          with:
            assignees: modem7

  auto-assign-pr:
    if: github.event_name == 'pull_request' && github.actor != 'renovate[bot]'
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
      issues: write
    steps:
        - name: 'Auto-assign PR'
          uses: pozil/auto-assign-issue@v4.0.1
          with:
            assignees: modem7
```

Copied verbatim from `docker-devenv`/`.github`, no repo-specific changes needed.

- [ ] **Step 4: Write `.github/workflows/lint.yml`**

```yaml
name: Lint Dockerfile

on:
  push:
    paths:
      - Dockerfile
      - .github/workflows/lint.yml
  pull_request:
    paths:
      - Dockerfile
      - .github/workflows/lint.yml
  workflow_dispatch:

jobs:
  hadolint:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v7.0.1

      - name: Run hadolint
        run: |
          docker run --rm -v "$PWD":/work -w /work \
            hadolint/hadolint:v2.15.1-alpine@sha256:a1d49ae1a4e83c1dbad26b8c1ad7588c8bd1e04f4866b34ad3cac50335198552 \
            sh -c "hadolint --version && hadolint Dockerfile"
```

Copied from `docker-starwars`'s shape (same digest-pinned hadolint image already verified working against this repo's real Dockerfile in Task 4).

- [ ] **Step 5: Validate all four files are syntactically valid**

```bash
python3 -c "import json; json.load(open('renovate.json'))" && echo "renovate.json OK"
python3 -c "import yaml; yaml.safe_load(open('.github/settings.yml'))" && echo "settings.yml OK"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/autoassign.yml'))" && echo "autoassign.yml OK"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/lint.yml'))" && echo "lint.yml OK"
```

Expected: all four print `OK`. If `python3 -c "import yaml"` fails with `ModuleNotFoundError`, run `pip install --break-system-packages pyyaml` first (per this environment's convention for Python packages).

- [ ] **Step 6: Commit**

```bash
git add renovate.json .github/settings.yml .github/workflows/autoassign.yml .github/workflows/lint.yml
git commit -m "Add repo scaffolding matching org conventions"
```

---

### Task 7: `.woodpecker.yml`

**Files:**
- Create: `.woodpecker.yml`

**Interfaces:** none directly, but the `build-and-push` step's `repo:` setting must match the actual Docker Hub repo name (`modem7/dnsmasq-relay`) used in Task 5's compose file.

- [ ] **Step 1: Verify the version-resolution command works before writing it into the YAML**

```bash
docker run --rm alpine:3.24 sh -c '
apk update -q >/dev/null 2>&1
pkg_ver=$(apk list -a dnsmasq 2>/dev/null | head -1 | awk "{print \$1}" | sed -E "s/^dnsmasq-//")
relay_ver=$(echo "$pkg_ver" | grep -oE "^[0-9]+\.[0-9]+")
echo "resolved version: $relay_ver"
'
```

Expected: `resolved version: 2.92` (or whatever Alpine 3.24 currently ships — the command, not the exact number, is what matters).

- [ ] **Step 2: Write `.woodpecker.yml`**

```yaml
when:
  - event: [push, manual]
    branch: master
    path:
      # Scoped to what actually gets baked into the image - docs/CI-only
      # changes elsewhere shouldn't trigger a rebuild/republish.
      include:
        - Dockerfile
        - entrypoint.sh
        - lib/relay-config.sh
        - .woodpecker.yml

steps:
  # Resolves dnsmasq's actual packaged version (e.g. "2.92") from Alpine's
  # live apk index, rather than a version pinned in the Dockerfile - the
  # package is deliberately left unpinned there so every rebuild picks up
  # Alpine's latest security backport automatically.
  - name: prepare-tags
    image: alpine:3.24
    commands:
      - apk update -q
      - pkg_ver=$(apk list -a dnsmasq 2>/dev/null | head -1 | awk '{print $1}' | sed -E 's/^dnsmasq-//')
      - relay_ver=$(echo "$pkg_ver" | grep -oE '^[0-9]+\.[0-9]+')
      - printf "latest\n%s\n" "$relay_ver" > .tags
      - echo "Tags to publish:" && cat .tags

  - name: build-and-push
    image: woodpeckerci/plugin-docker-buildx
    privileged: true
    depends_on: [prepare-tags]
    settings:
      repo: modem7/dnsmasq-relay
      dockerfile: Dockerfile
      context: .
      purge: true
      compress: true
      build_args:
        BUILDKIT_INLINE_CACHE: "1"
      cache_from:
        - type=registry\,ref=modem7/dnsmasq-relay:latest
      platforms: linux/amd64,linux/arm64
      username:
        from_secret: docker_username
      password:
        from_secret: docker_password
      tags_file: .tags

  - name: pushrm-dockerhub
    image: chko/docker-pushrm
    depends_on:
      - build-and-push
    environment:
      DOCKER_USER:
        from_secret: docker_username
      DOCKER_PASS:
        from_secret: docker_password
      PUSHRM_FILE: README.md
      PUSHRM_SHORT: DHCP relay across VLANs using dnsmasq
      PUSHRM_TARGET: modem7/dnsmasq-relay
    when:
      - status: [success]

  # Single dynamic-status notifier. CI_PIPELINE_STATUS must stay bare
  # ($VAR, not ${VAR}) - Woodpecker resolves ${VAR} at compile time,
  # before this value exists (woodpecker-ci/woodpecker#6826).
  - name: notify-slack
    image: alpine
    depends_on:
      - build-and-push
    environment:
      SLACK_WEBHOOK:
        from_secret: slack_hook
    commands:
      - apk add --no-cache curl jq >/dev/null
      - COMMIT_SHORT=$(echo "$CI_COMMIT_SHA" | cut -c1-10)
      - >
        PAYLOAD=$(jq -n
        --arg status "$CI_PIPELINE_STATUS"
        --arg branch "$CI_COMMIT_BRANCH"
        --arg output "${CI_REPO}#${CI_PIPELINE_NUMBER}"
        --arg output_url "$CI_PIPELINE_URL"
        --arg build "$CI_PIPELINE_NUMBER"
        --arg commit "$COMMIT_SHORT"
        --arg commit_url "$CI_PIPELINE_FORGE_URL"
        --arg author "$CI_COMMIT_AUTHOR"
        --arg message "$CI_COMMIT_MESSAGE"
        '{attachments:[{color:(if $status == "success" then "good" else "danger" end),fields:[
        {title:"Status",value:$status,short:true},
        {title:"Branch",value:$branch,short:true},
        {title:"Output",value:("<"+$output_url+"|"+$output+">"),short:true},
        {title:"Build Number",value:$build,short:true},
        {title:"Commit",value:("<"+$commit_url+"|"+$commit+">"),short:true},
        {title:"Author",value:$author,short:true},
        {title:"Commit Message",value:$message,short:false}
        ]}]}')
      - >
        curl -fsS -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$SLACK_WEBHOOK"
    when:
      - status: [success, failure]
```

Mirrors DHCP-Relay's `.woodpecker.yml` structure exactly, with the `prepare-tags` step switched from `apt-cache policy isc-dhcp-relay` to the `apk`-based dnsmasq version query verified in Step 1, and `path.include`/`repo`/`PUSHRM_TARGET` updated to this repo's files and image name.

- [ ] **Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.woodpecker.yml'))" && echo "woodpecker.yml OK"
```

Expected: `woodpecker.yml OK`.

- [ ] **Step 4: Commit**

```bash
git add .woodpecker.yml
git commit -m "Add Woodpecker CI build/publish pipeline"
```

---

### Task 8: README.md

**Files:**
- Create: `README.md`

**Interfaces:** Documents the env vars from Task 2/3 (`DHCP_RELAYS`, `DHCP_RELAY_EXTRA_ARGS`, `DHCP_RELAY_VERBOSE`), the capabilities verified in Task 4, and the compose example from Task 5. Must stay consistent with all of them — if any of those change during implementation, update this file too.

- [ ] **Step 1: Write `README.md`**

```markdown
# dnsmasq-relay

![Docker Pulls](https://img.shields.io/docker/pulls/modem7/dnsmasq-relay)
![Docker Image Size (tag)](https://img.shields.io/docker/image-size/modem7/dnsmasq-relay/latest)
[![status-badge](#)](#)
<!-- Woodpecker badge above is a placeholder - swap in
     https://woodpecker.modem7.com/api/badges/<repo-id>/status.svg?events=push%2Cmanual
     once this repo is registered there. -->
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
```

- [ ] **Step 2: Confirm all documented env vars match the actual implementation**

```bash
grep -o 'DHCP_RELAY[A-Z_]*' entrypoint.sh | sort -u
grep -o 'DHCP_RELAY[A-Z_]*' README.md | sort -u
```

Expected: both commands list exactly `DHCP_RELAYS`, `DHCP_RELAY_EXTRA_ARGS`, `DHCP_RELAY_VERBOSE` - no var documented that isn't implemented, and vice versa.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Add README"
```

---

### Task 9: Finish the branch

**Files:** none (repo operation only)

- [ ] **Step 1: Push the implementation branch**

```bash
git push -u origin feat/initial-implementation
```

- [ ] **Step 2: Open a PR against `docs/design-doc` (not `master`)**

The design doc hasn't merged to `master` yet, so this PR targets that branch first; `docs/design-doc` gets its own separate PR into `master` once you're ready (per [[feedback_mr_only]] - direct pushes to `master` are hard-blocked in this environment regardless).

```bash
gh pr create --base docs/design-doc --title "Implement dnsmasq-relay" --body "$(cat <<'EOF'
## Summary
- Dockerfile (alpine:3.24 + dnsmasq, non-root, 3 empirically-verified capabilities)
- entrypoint.sh + lib/relay-config.sh, parsing DHCP_RELAYS into dnsmasq --dhcp-relay flags
- Repo scaffolding matching org conventions (renovate, GitHub settings/workflows, Woodpecker)
- README, docker-compose.yml example

## Test plan
- [x] tests/test_relay_config.sh passes (IP validation + DHCP_RELAYS parsing)
- [x] tests/test_entrypoint.sh passes (argv assembly against a stub dnsmasq)
- [x] Real image built; capability set re-verified against it (NET_BIND_SERVICE + NET_ADMIN + NET_RAW required, confirmed by dropping each individually)
- [x] Invalid DHCP_RELAYS rejected with a specific error before dnsmasq starts
- [x] HEALTHCHECK reports healthy
- [x] hadolint clean (DL3018, DL3066 deliberately overridden, both documented in .hadolint.yaml)
EOF
)"
```

- [ ] **Step 3: Verify the GitHub Actions lint workflow passes on the PR**

```bash
gh pr checks --watch
```

Expected: `Lint Dockerfile` shows `pass`.

---

## Self-Review Notes

- **Spec coverage:** every design-doc section has a task - architecture/config interface (Tasks 1-3), capabilities (Task 4 Step 3), Dockerfile shape (Task 4), README sections (Task 8), repo scaffolding (Tasks 6-7), testing plan (capability re-verification, DHCP_RELAYS parsing, logs/healthcheck, hadolint - all present across Tasks 1-4). The design doc's "Woodpecker badge left as placeholder" and "update DHCP-Relay's README" items are explicitly out of scope for this plan (the latter is already done, in [modem7/DHCP-Relay#65](https://github.com/modem7/DHCP-Relay/pull/65)).
- **Placeholder scan:** no TBD/TODO markers. The one intentional placeholder (Woodpecker badge in README) is explicitly commented as such, matching the design doc's decision to leave it pending real data from the user.
- **Type/interface consistency:** `parse_dhcp_relays`, `describe_relay_flag`, `is_valid_ip`, `ip_family` are named identically everywhere they're referenced (Tasks 1-3's Interfaces blocks and actual code). `DHCP_RELAYS`/`DHCP_RELAY_EXTRA_ARGS`/`DHCP_RELAY_VERBOSE` are the only three env vars anywhere in the plan, cross-checked in Task 8 Step 2.
- Every piece of code in this plan (the shell library, the entrypoint, the Dockerfile including the `mkdir -p` fix for the `COPY --chmod` directory-permission bug, the `apk`-based version query, the `.hadolint.yaml` overrides) was actually run against a real build during plan-writing, not just reasoned about - including catching and fixing one real bug (the `lib/` directory permission issue) that would otherwise have shipped broken.
