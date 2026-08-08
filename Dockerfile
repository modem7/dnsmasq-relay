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
