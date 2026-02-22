ARG PG_VERSION=18
ARG POSTGIS_VERSION=3.6

FROM postgis/postgis:${PG_VERSION}-${POSTGIS_VERSION}

ARG PG_VERSION
ENV PG_VERSION=${PG_VERSION}

LABEL authors="rohittp"

RUN apt-get update && \
    apt-get install -y --no-install-recommends pgbackrest cron jq curl && \
    rm -rf /var/lib/apt/lists/*

COPY pg-rocket-entrypoint.sh backup.sh restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/pg-rocket-entrypoint.sh \
             /usr/local/bin/backup.sh \
             /usr/local/bin/restore.sh

ENTRYPOINT ["pg-rocket-entrypoint.sh"]
CMD ["postgres"]
