# KDB-X Community Edition (linux/arm64 or amd64). Licence is mounted at runtime, never baked in.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip rlwrap \
    && rm -rf /var/lib/apt/lists/*

ARG KX_URL=https://portal.dl.kx.com/assets/raw/kdb-x
ENV QHOME=/opt/kx/q PATH=/opt/kx/bin:$PATH QLIC=/opt/kx/lic

# q binary for this arch + SQL interface (s.k_ is arch-independent; the arm64 SQL zip doesn't exist)
RUN set -eux; \
    case "$(uname -m)" in aarch64) P=l64arm ;; x86_64) P=l64 ;; *) exit 1 ;; esac; \
    mkdir -p /opt/kx/bin "$QHOME" /tmp/kx && cd /tmp/kx; \
    curl -fsSL -o q.zip "$KX_URL/kdb-x/~latest~/$P.zip" && unzip -q q.zip && mv */q /opt/kx/bin/q; \
    curl -fsSL -o sql.zip "$KX_URL/sql/~latest~/l64-sql.zip" && unzip -q sql.zip s.k_ && mv s.k_ "$QHOME/"; \
    chmod +x /opt/kx/bin/q; rm -rf /tmp/kx

RUN useradd -r -m -d /home/kdb kdb
USER kdb
WORKDIR /opt/app
