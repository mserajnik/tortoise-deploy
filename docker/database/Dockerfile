# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

ARG DEBIAN_FRONTEND=noninteractive
ARG TORTOISE_REPOSITORY_URL=https://github.com/Penqle/tortoise-wow.git
ARG TORTOISE_REVISION=main
ARG TORTOISE_MIGRATION_EDITS=

FROM mariadb:12.3 AS build

ARG DEBIAN_FRONTEND
ARG TORTOISE_REPOSITORY_URL
ARG TORTOISE_REVISION

RUN \
  apt update && \
  apt install -y --no-install-recommends \
    git && \
  git clone "$TORTOISE_REPOSITORY_URL" /build/core && \
  cd /build/core && \
  git checkout "$TORTOISE_REVISION" && \
  mkdir -p /sql/base /sql/custom && \
  cp /build/core/sql/create_databases.sql /sql/create_databases.sql && \
  cp /build/core/sql/base/*.sql /sql/base/

FROM mariadb:12.3

ARG TORTOISE_MIGRATION_EDITS

# See https://github.com/MariaDB/mariadb-docker/blob/f8552c80b5104868ff1bb88851ca976bd99029ee/12.3/docker-entrypoint.sh#L595-L599
ENV MARIADB_AUTO_UPGRADE=1
ENV MARIADB_USER=mangos
ENV MARIADB_PASSWORD=mangos
ENV MARIADB_ROOT_PASSWORD=password
ENV TORTOISE_REALMLIST_NAME=Tortoise-WoW
ENV TORTOISE_REALMLIST_ADDRESS=127.0.0.1
ENV TORTOISE_REALMLIST_PORT=8085
ENV TORTOISE_REALMLIST_ICON=1
ENV TORTOISE_REALMLIST_TIMEZONE=0
ENV TORTOISE_REALMLIST_ALLOWED_SECURITY_LEVEL=0
ENV TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS=1
ENV TORTOISE_PROCESS_CUSTOM_SQL=1

COPY --from=build /sql /sql

RUN \
  mkdir -p /opt/scripts && \
  mkdir /always-initdb.d && \
  printf '%s\n' "$TORTOISE_MIGRATION_EDITS" >/sql/migration-edits

COPY ./docker/database/db-functions.sh /opt/scripts
COPY --chmod=755 ./docker/database/create-db.sh /docker-entrypoint-initdb.d
COPY --chmod=755 ./docker/database/update-db.sh /always-initdb.d
COPY --chmod=755 ./docker/database/healthcheck.sh /usr/local/bin/tortoise-healthcheck

COPY --chmod=755 ./docker/database/docker-entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["mariadbd"]
