FROM debian:bookworm-slim

LABEL authors="rohittp"

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates gnupg curl && \
    echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg && \
    apt-get update && \
    apt-get install -y --no-install-recommends pgbackrest tzdata bash coreutils util-linux curl jq && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

