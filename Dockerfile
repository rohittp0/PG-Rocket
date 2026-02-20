FROM debian:bookworm-slim

LABEL authors="rohittp"

RUN apt-get update
RUN apt-get install -y --no-install-recommends pgbackrest ca-certificates tzdata bash coreutils util-linux curl jq
RUN rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

