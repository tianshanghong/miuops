FROM postgres:17

ARG WALG_VERSION=v3.0.8
ARG TARGETARCH

RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) WALG_ARCH=amd64 ;; \
        arm64) WALG_ARCH=aarch64 ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    WALG_BINARY="wal-g-pg-24.04-${WALG_ARCH}"; \
    apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget \
    && wget -q "https://github.com/wal-g/wal-g/releases/download/${WALG_VERSION}/${WALG_BINARY}" \
       -O /usr/local/bin/wal-g \
    && wget -q "https://github.com/wal-g/wal-g/releases/download/${WALG_VERSION}/${WALG_BINARY}.sha256" \
       -O /tmp/wal-g.sha256 \
    && echo "$(awk '{print $1}' /tmp/wal-g.sha256)  /usr/local/bin/wal-g" | sha256sum -c - \
    && rm /tmp/wal-g.sha256 \
    && chmod +x /usr/local/bin/wal-g \
    && apt-get purge -y --auto-remove wget \
    && rm -rf /var/lib/apt/lists/*

COPY walg-backup.sh /usr/local/bin/walg-backup.sh

CMD ["postgres", \
     "-c", "wal_level=replica", \
     "-c", "archive_mode=on", \
     "-c", "archive_command=wal-g wal-push %p", \
     "-c", "archive_timeout=60"]
