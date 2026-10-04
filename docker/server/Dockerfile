# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

ARG DEBIAN_FRONTEND=noninteractive
ARG TORTOISE_REPOSITORY_URL=https://github.com/tortoise-wow/tortoise-wow.git
ARG TORTOISE_REVISION=main
ARG TORTOISE_MODULES=
ARG TORTOISE_MODULE_CONFIGS=
ARG TORTOISE_MODULE_SQL_MODULES=
ARG TORTOISE_MODULE_BUILD_PACKAGES=
ARG TORTOISE_FAIL_ON_PATCH_ERROR=0

FROM ubuntu:26.04 AS build

ARG DEBIAN_FRONTEND
ARG TORTOISE_REPOSITORY_URL
ARG TORTOISE_REVISION
ARG TORTOISE_MODULES
ARG TORTOISE_MODULE_CONFIGS
ARG TORTOISE_MODULE_SQL_MODULES
ARG TORTOISE_MODULE_BUILD_PACKAGES
ARG TORTOISE_FAIL_ON_PATCH_ERROR

COPY ./docker/patches /build/patches

# A module can need packages its build does not declare, such as the Boost
# headers TortoiseBots includes. `TORTOISE_MODULE_BUILD_PACKAGES` adds them,
# unquoted, so apt gets one argument per package.
RUN \
  apt update && \
  apt install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    git \
    libace-dev \
    libmysqlclient-dev \
    libssl-dev \
    zlib1g-dev \
    $TORTOISE_MODULE_BUILD_PACKAGES && \
  git clone "$TORTOISE_REPOSITORY_URL" /build/core && \
  cd /build/core && \
  git checkout "$TORTOISE_REVISION" && \
  patch_count=0 && \
  for patch in /build/patches/*.patch; do \
    if [ -f "$patch" ]; then \
      echo "Applying patch '$patch'."; \
      if ! git apply "$patch"; then \
        echo "Failed to apply patch '$patch'."; \
        if [ "$TORTOISE_FAIL_ON_PATCH_ERROR" = "1" ]; then \
          exit 1; \
        fi; \
      fi; \
      patch_count=$((patch_count + 1)); \
    fi; \
  done && \
  if [ "$patch_count" -eq 0 ]; then \
    echo "No patches found."; \
  fi && \
  if [ -n "$TORTOISE_MODULES" ]; then \
    # `<directory>=<url>@<revision>` entries separated by `|`. The generated
    # loader calls `Add<directory>Scripts`, with every non-alphanumeric
    # character replaced by `_`, so the directory name has to match the
    # module's code. `set -e` does not apply inside this AND-OR list, so each
    # step that can fail needs its own `|| exit 1`.
    ( \
      IFS='|'; \
      for module in $TORTOISE_MODULES; do \
        module_directory="${module%%=*}"; \
        module_source="${module#*=}"; \
        module_url="${module_source%@*}"; \
        module_revision="${module_source##*@}"; \
        module_path="/build/core/modules/$module_directory"; \
        echo "Cloning module '$module_directory' from $module_url at $module_revision."; \
        git clone "$module_url" "$module_path" || exit 1; \
        git -C "$module_path" checkout "$module_revision" || exit 1; \
        # Upstream compiles a module in only when it has a `src/` directory.
        if [ ! -d "$module_path/src" ]; then \
          echo "Module '$module_directory' has no 'src/' directory and would not be compiled in."; \
          exit 1; \
        fi; \
      done; \
    ); \
  else \
    echo "No modules requested."; \
  fi && \
  mkdir -p \
    /opt/tortoise/config \
    /opt/tortoise/storage/honor \
    /opt/tortoise/storage/logs \
    /opt/tortoise/storage/pdump && \
  mkdir /build/core/build && \
  cd /build/core/build && \
  cmake \
    -DCMAKE_INSTALL_PREFIX=/opt/tortoise ../ \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DUSE_ANTICHEAT=OFF \
    -DUSE_EXTRACTORS=ON \
    -DENABLE_SOAP=ON \
    -DDEBUG_SYMBOLS=0 \
    ${TORTOISE_MODULES:+-DMODULES=static} && \
  make -j"$(nproc)" && \
  make install && \
  if [ -n "$TORTOISE_MODULES" ]; then \
    # List the module configuration files, relative to the configuration
    # directory, so the container command can report a missing one. The core
    # installs only `.dist` files, so a plain `.conf` belongs to a module, such
    # as TortoiseBots' top-level `aiplayerbot.conf`.
    { \
      for module_config_dist in /opt/tortoise/etc/modules/*.conf.dist; do \
        if [ -f "$module_config_dist" ]; then \
          printf 'modules/%s\n' "$(basename "$module_config_dist" .dist)"; \
        fi; \
      done; \
      for module_config in /opt/tortoise/etc/*.conf; do \
        if [ -f "$module_config" ]; then \
          basename "$module_config"; \
        fi; \
      done; \
      for module_config in /opt/tortoise/etc/modules/*.conf; do \
        if [ -f "$module_config" ]; then \
          printf 'modules/%s\n' "$(basename "$module_config")"; \
        fi; \
      done; \
    } >/opt/tortoise/module-configs; \
    # The comparison below is a string compare, so `module-configs` in
    # `.github/deploy.yaml` has to list the files in C-locale order. `-u`
    # because a module that installs both a `.conf` and its own `.conf.dist`
    # appears twice above.
    LC_ALL=C sort -u -o /opt/tortoise/module-configs /opt/tortoise/module-configs; \
    # A module that adds or renames a configuration file would stop every
    # container of the variant on a missing bind mount.
    installed_module_configs="$(tr '\n' ',' </opt/tortoise/module-configs)"; \
    if [ "${installed_module_configs%,}" != "$TORTOISE_MODULE_CONFIGS" ]; then \
      echo "This build requires the module configuration files '${installed_module_configs%,}', but the variant declares '$TORTOISE_MODULE_CONFIGS'."; \
      exit 1; \
    fi; \
    # `mangosd` applies a module's SQL only from
    # `/opt/tortoise/modules/<module>/data/sql/<target>` and skips anything
    # else without a word, so check where `make install` put each SQL file a
    # module provides. Only the modules in `TORTOISE_MODULE_SQL_MODULES` may
    # provide SQL. A failed `find` aborts, because two empty lists would
    # compare equal.
    ( \
      IFS='|'; \
      for module in $TORTOISE_MODULES; do \
        module_directory="${module%%=*}"; \
        module_path="/build/core/modules/$module_directory"; \
        installed_sql="/opt/tortoise/modules/$module_directory/data/sql"; \
        : >/build/module-sql-expected; \
        : >/build/module-sql-installed; \
        find -L "$module_path" -xdev -type f -iname '*.sql' \
          -not -path "$module_path/.git/*" -printf '%P\n' \
          >/build/module-sql-shipped || exit 1; \
        if [ -s /build/module-sql-shipped ]; then \
          case ",$TORTOISE_MODULE_SQL_MODULES," in \
            *",$module_directory,"*) ;; \
            *) \
              echo "Module '$module_directory' ships SQL, which this variant does not apply. Only the modules named in 'TORTOISE_MODULE_SQL_MODULES' may carry SQL."; \
              exit 1 ;; \
          esac; \
        fi; \
        while IFS= read -r shipped_path; do \
          case "$shipped_path" in \
            data/sql/char/*/*|data/sql/world/*/*) \
              echo "Module '$module_directory' ships the SQL file '$shipped_path' in a subdirectory. The applier does not descend, so the file would never be applied."; \
              exit 1 ;; \
            data/sql/char/*) target=character ;; \
            data/sql/world/*) target=world ;; \
            *) \
              echo "Module '$module_directory' ships the SQL file '$shipped_path', which this image maps to no database."; \
              exit 1 ;; \
          esac; \
          printf '%s/%s\n' "$target" "${shipped_path##*/}" \
            >>/build/module-sql-expected; \
        done </build/module-sql-shipped; \
        if [ -d "$installed_sql" ]; then \
          find -L "$installed_sql" -mindepth 2 -maxdepth 2 -xdev -type f \
            -name '*.sql' \
            \( -path "$installed_sql/auth/*" \
              -o -path "$installed_sql/character/*" \
              -o -path "$installed_sql/world/*" \) \
            -printf '%P\n' >/build/module-sql-installed || exit 1; \
        fi; \
        LC_ALL=C sort -o /build/module-sql-expected /build/module-sql-expected; \
        LC_ALL=C sort -o /build/module-sql-installed /build/module-sql-installed; \
        if ! cmp -s /build/module-sql-expected /build/module-sql-installed; then \
          expected_list="$(tr '\n' ',' </build/module-sql-expected)"; \
          installed_list="$(tr '\n' ',' </build/module-sql-installed)"; \
          echo "Module '$module_directory' has to install the SQL files '${expected_list%,}' under '$installed_sql', but installed '${installed_list%,}'."; \
          exit 1; \
        fi; \
      done; \
    ); \
  fi && \
  # `mangosd` applies the migrations from one directory per database, so a flat
  # upstream migration is moved into `world`. It keys a migration by its
  # content hash, so the move does not apply it again. Create the directories
  # first, because `mangosd` creates a missing one without checking for errors.
  mkdir -p \
    /opt/tortoise/sql/database_updates/auth \
    /opt/tortoise/sql/database_updates/character \
    /opt/tortoise/sql/database_updates/world && \
  cp -r /build/core/sql/database_updates/. /opt/tortoise/sql/database_updates/ && \
  find /opt/tortoise/sql/database_updates -maxdepth 1 -type f -name '*.sql' \
    -exec mv -n -t /opt/tortoise/sql/database_updates/world/ {} + && \
  # Tortoise-WoW installs only the `MoveMapGen` binary, without its data.
  cp \
    /build/core/tools/mmap/mmapSettings.txt \
    /build/core/tools/mmap/offmesh.txt \
    /opt/tortoise/bin/ && \
  # Turn Tortoise-WoW's DBC hash table into a `sha256sum -c` manifest, which
  # spares the image a Python install. The parse accepts either quote and hash
  # case, and lowercases the extension to the name the extractors write.
  sed -n \
    -e "s/\\.[Dd][Bb][Cc]\\(['\"][[:space:]]*:\\)/.dbc\\1/" \
    -e "s/^[[:space:]]*['\"]\\([^'\"]*\\.dbc\\)['\"][[:space:]]*:[[:space:]]*['\"]\\([0-9a-fA-F]\\{64\\}\\)['\"][^'\"]*\$/\\2  \\1/p" \
    /build/core/tools/dbc_verification/dbc_verifier.py \
    >/opt/tortoise/dbc-hashes && \
  dbc_hash_count="$(grep -cE '^[0-9a-fA-F]{64}  ' /opt/tortoise/dbc-hashes || true)" && \
  dbc_hash_count="${dbc_hash_count:-0}" && \
  if [ "$dbc_hash_count" -lt 100 ]; then \
    echo "Parsed $dbc_hash_count DBC hashes from 'tools/dbc_verification/dbc_verifier.py', which is too few for a complete manifest."; \
    exit 1; \
  fi && \
  # An image with a partial manifest would refuse every client.
  dbc_key_count="$(grep -cE "^[[:space:]]*['\"][^'\"]*\\.[Dd][Bb][Cc]['\"][[:space:]]*:" \
    /build/core/tools/dbc_verification/dbc_verifier.py)" && \
  if [ "$dbc_hash_count" -ne "$dbc_key_count" ]; then \
    echo "Parsed $dbc_hash_count DBC hashes from 'tools/dbc_verification/dbc_verifier.py', which names $dbc_key_count DBC files."; \
    exit 1; \
  fi && \
  # A duplicate entry can hide a missing one.
  dbc_unique_count="$(awk '{ sub(/^[^ ]*  /, "") } !seen[$0]++ { n++ } END { print n + 0 }' /opt/tortoise/dbc-hashes)" && \
  if [ "$dbc_hash_count" -ne "$dbc_unique_count" ]; then \
    echo "Parsed $dbc_hash_count DBC hashes from 'tools/dbc_verification/dbc_verifier.py' for only $dbc_unique_count distinct DBC files."; \
    exit 1; \
  fi

FROM ubuntu:26.04

ARG DEBIAN_FRONTEND

RUN \
  apt update && \
  apt install -y --no-install-recommends \
    ca-certificates \
    libace-8.0.5 \
    libmysqlclient24 \
    libssl3t64 \
    netcat-openbsd \
    tzdata \
    zlib1g && \
  # The image's `ubuntu` user already has UID and GID 1000.
  groupmod -n tortoise ubuntu && \
  usermod -l tortoise -d /home/tortoise -m ubuntu && \
  apt autoremove -y && \
  apt clean -y && \
  rm -rf /var/lib/apt/lists/*

# The configuration files come from a bind mount.
COPY --from=build --exclude=tortoise/etc* --chown=tortoise:tortoise /opt /opt

COPY ./docker/check-deploy-version.sh /usr/local/lib/tortoise-deploy/check-deploy-version.sh
COPY ./docker/server/drop-privileges.sh /usr/local/lib/tortoise-deploy/drop-privileges.sh
COPY --chmod=755 ./docker/server/docker-cmd-mangosd.sh /usr/local/bin/mangosd
COPY --chmod=755 ./docker/server/docker-cmd-realmd.sh /usr/local/bin/realmd
COPY --chmod=755 ./docker/server/docker-cmd-extract-client-data.sh /usr/local/bin/extract-client-data
COPY --chmod=755 ./docker/server/docker-cmd-verify-client-data.sh /usr/local/bin/verify-client-data
COPY --chmod=755 ./docker/server/docker-cmd-check-deploy-version.sh /usr/local/bin/check-deploy-version
# Ubuntu keeps package license information under `/usr/share/doc`.
COPY ./docker/docker-notice.txt /usr/share/doc/tortoise-deploy/NOTICE

WORKDIR /home/tortoise
CMD ["mangosd"]
