# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

ARG DEBIAN_FRONTEND=noninteractive
ARG TORTOISE_REPOSITORY_URL=https://github.com/tortoise-wow/tortoise-wow.git
ARG TORTOISE_REVISION=main
ARG TORTOISE_MODULES=
ARG TORTOISE_MODULE_CONFIGS=
ARG TORTOISE_MODULE_SQL_MODULES=
ARG TORTOISE_MODULE_BUILD_PACKAGES=
ARG TORTOISE_PATCHES_REPOSITORY_URL
ARG TORTOISE_FAIL_ON_PATCH_ERROR=0
ARG TORTOISE_PATCH_SET=base
ARG TORTOISE_USER_ID=1000
ARG TORTOISE_GROUP_ID=1000
ARG TORTOISE_USER_NAME=tortoise
ARG TORTOISE_GROUP_NAME=tortoise

FROM ubuntu:26.04 AS build

ARG DEBIAN_FRONTEND
ARG TORTOISE_REPOSITORY_URL
ARG TORTOISE_REVISION
ARG TORTOISE_MODULES
ARG TORTOISE_MODULE_CONFIGS
ARG TORTOISE_MODULE_SQL_MODULES
ARG TORTOISE_MODULE_BUILD_PACKAGES
ARG TORTOISE_PATCHES_REPOSITORY_URL
ARG TORTOISE_FAIL_ON_PATCH_ERROR
ARG TORTOISE_PATCH_SET

# The packages below are what the core needs. A module may need more, and a
# module can leave that requirement undeclared. TortoiseBots includes six Boost
# headers directly, and its build declares neither a `find_package` nor a link
# rule for them. Each variant supplies such packages through
# `TORTOISE_MODULE_BUILD_PACKAGES`, which the matrix sets. A variant without
# such a module installs exactly what it did before. This passes the value
# unquoted on purpose, because apt takes it split into arguments.
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
  if [ -n "$TORTOISE_PATCHES_REPOSITORY_URL" ]; then \
    echo "Cloning and applying patches from $TORTOISE_PATCHES_REPOSITORY_URL."; \
    git clone "$TORTOISE_PATCHES_REPOSITORY_URL" /build/patches || exit 1; \
    patch_count=0; \
    # Patches in `all` are applied to every image. Patches in the
    # `TORTOISE_PATCH_SET` directory, which is optional and may not exist, are
    # applied only to images built with that set. Every patch applies to
    # `/build/core`.
    for patch in \
      /build/patches/all/*.patch \
      /build/patches/"$TORTOISE_PATCH_SET"/*.patch; \
    do \
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
    done; \
    if [ "$patch_count" -eq 0 ]; then \
      echo "No patches found."; \
    fi; \
  else \
    echo "No repository to apply patches from provided."; \
  fi && \
  if [ -n "$TORTOISE_MODULES" ]; then \
    # Bundled modules for a bundled-module variant, as
    # `<directory>=<url>@<revision>` entries separated by `|`. They are cloned
    # after the patch loop because every patch targets the core itself. The
    # directory name is load-bearing: the generated loader calls
    # `Add<directory>Scripts` with each non-alphanumeric character replaced by
    # `_`, and the module's own source has to define exactly that symbol.
    # The clone and the checkout need their own `|| exit 1` because the shell
    # ignores `set -e` for any command of an AND-OR list other than the last,
    # and this subshell runs inside one.
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
        # Upstream discovers a module by its `src/` directory, so a clone that
        # lands anywhere else, or a repository that is not a module at all,
        # would otherwise produce an image silently missing it.
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
    /opt/tortoise/storage/client-data \
    /opt/tortoise/storage/extracted-data \
    /opt/tortoise/storage/honor \
    /opt/tortoise/storage/logs && \
  mkdir /build/core/build && \
  cd /build/core/build && \
  cmake \
    -DCMAKE_INSTALL_PREFIX=/opt/tortoise ../ \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DUSE_ANTICHEAT=OFF \
    -DUSE_EXTRACTORS=ON \
    -DDEBUG_SYMBOLS=0 \
    ${TORTOISE_MODULES:+-DMODULES=static} && \
  make -j"$(nproc)" && \
  make install && \
  if [ -n "$TORTOISE_MODULES" ]; then \
    # Record the module configuration files this image needs at startup so the
    # container command can report a missing one. The names come from what
    # `make install` put under `/opt/tortoise/etc`, which the runtime `COPY`
    # excludes. The manifest at `/opt/tortoise/module-configs` is outside that
    # exclusion.
    #
    # Each entry is a path relative to the configuration directory, because a
    # module may install a file beside `mangosd.conf`, outside `modules/`. The
    # core installs only `.dist` templates at either level, so a plain `.conf`
    # belongs to a module wherever it is. The check leaves out a template at
    # the top level, because the core's own `realmd.conf.dist` is there.
    # TortoiseBots installs `aiplayerbot.conf` that way. When that file is
    # missing, the module logs one line and disables itself, which the startup
    # check exists to prevent.
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
    # The comparison below is a string compare, so both sides have to agree on
    # order. Sorting in the C locale matches what `prepare-build-matrix.sh`
    # emits, whatever locale it happens to run under. `-u` because a module
    # that installs both a `.conf` and its own `.conf.dist` appears twice
    # above.
    LC_ALL=C sort -u -o /opt/tortoise/module-configs /opt/tortoise/module-configs; \
    # Refuse to publish an image whose installed configuration set differs from
    # the list this variant declared. Module code floats, so a module can add
    # or rename a template between builds, and either would make every variant
    # container exit on startup for want of a bind mount nobody knew to add.
    # This also catches an empty list, which would otherwise leave the startup
    # check with nothing to verify.
    installed_module_configs="$(tr '\n' ',' </opt/tortoise/module-configs)"; \
    if [ "${installed_module_configs%,}" != "$TORTOISE_MODULE_CONFIGS" ]; then \
      echo "This build requires the module configuration files '${installed_module_configs%,}', but the variant declares '$TORTOISE_MODULE_CONFIGS'."; \
      exit 1; \
    fi; \
    # The applier reads a module's SQL from `/opt/tortoise/modules`, where the
    # `use-installed-module-sql-path` patch points `TW_SOURCE_MODULES_DIR`. The
    # applier reads `<module>/data/sql/<target>` for the three targets pinned
    # by `pin-migration-paths`. A file installed under any other name is never
    # applied, and nothing in the log says so. The check runs after
    # `make install`, which is what puts the files in place.
    #
    # The check maps each file the module provides to the target it has to end
    # up under, then compares the result with what `make install` produced. The
    # mapping covers the source directories the bundled modules use. A module
    # that uses a different one fails this build until the mapping gains it.
    # TortoiseBots provides `char/` and installs it as `character/`.
    #
    # Both searches abort the build on a `find` failure, because two empty
    # lists compare equal and would pass.
    #
    # A module may provide SQL only while `TORTOISE_MODULE_SQL_MODULES` lists
    # it. That list is empty for every variant sharing another unit's database
    # image. A curated module that grows a `data/sql/` directory then fails
    # this build.
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
  # Stage the migrations so `mangosd` can apply them at startup. The applier
  # reads `/opt/tortoise/sql/database_updates/` with one directory per
  # database, so both upstream layouts have to end up in that shape: migrations
  # may be organized into per-database subdirectories, or kept flat, where
  # every file is a world migration. A migration is keyed by the SHA-1 of its
  # content, so re-homing a file does not re-apply it.
  # Pre-creating the three directories also keeps the applier from creating a
  # missing one at runtime, which it does without guarding against a failure.
  mkdir -p \
    /opt/tortoise/sql/database_updates/auth \
    /opt/tortoise/sql/database_updates/character \
    /opt/tortoise/sql/database_updates/world && \
  cp -r /build/core/sql/database_updates/. /opt/tortoise/sql/database_updates/ && \
  find /opt/tortoise/sql/database_updates -maxdepth 1 -type f -name '*.sql' \
    -exec mv -n -t /opt/tortoise/sql/database_updates/world/ {} + && \
  # `MoveMapGen` needs these data files passed explicitly (see the extraction
  # command wrapper); Tortoise-WoW's build installs only the binary, so we
  # stage them alongside it.
  cp \
    /build/core/tools/mmap/mmapSettings.txt \
    /build/core/tools/mmap/offmesh.txt \
    /opt/tortoise/bin/ && \
  # Turn Tortoise-WoW's hash table into a `sha256sum -c` manifest. The runtime
  # then checks extracted DBC data without a Python interpreter. The table also
  # lists `hashes.txt`, which the extractors never produce. The parse takes
  # only the `.dbc` entries.
  #
  # The pattern accepts either quote character and either hash case, because a
  # regenerated table may change the quoting or the hash case. `sha256sum -c`
  # reads both cases. The extension is lowercased first, to match the name the
  # extractors write.
  #
  # The floor below catches a parse that returns an implausible number of
  # `.dbc` entries.
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
  # A partial parse passes the floor and still loses hashes, which leaves an
  # image that refuses every client. The parsed hashes have to match the
  # table's `.dbc` keys, and a key whose value the parse cannot read fails the
  # build. The key counter reads only lines that begin with a quoted `.dbc`
  # key.
  dbc_key_count="$(grep -cE "^[[:space:]]*['\"][^'\"]*\\.[Dd][Bb][Cc]['\"][[:space:]]*:" \
    /build/core/tools/dbc_verification/dbc_verifier.py)" && \
  if [ "$dbc_hash_count" -ne "$dbc_key_count" ]; then \
    echo "Parsed $dbc_hash_count DBC hashes from 'tools/dbc_verification/dbc_verifier.py', which names $dbc_key_count DBC files."; \
    exit 1; \
  fi && \
  # A duplicated entry alongside an omitted one keeps the line count, and the
  # runtime check then rejects the client data for a defect in the image.
  dbc_unique_count="$(awk '{ sub(/^[^ ]*  /, "") } !seen[$0]++ { n++ } END { print n + 0 }' /opt/tortoise/dbc-hashes)" && \
  if [ "$dbc_hash_count" -ne "$dbc_unique_count" ]; then \
    echo "Parsed $dbc_hash_count DBC hashes from 'tools/dbc_verification/dbc_verifier.py' for only $dbc_unique_count distinct DBC files."; \
    exit 1; \
  fi

FROM ubuntu:26.04

ARG TARGETARCH
ARG DEBIAN_FRONTEND
ARG TORTOISE_USER_ID
ARG TORTOISE_GROUP_ID
ARG TORTOISE_USER_NAME
ARG TORTOISE_GROUP_NAME

RUN \
  apt update && \
  apt install -y --no-install-recommends \
    ca-certificates \
    curl \
    libace-8.0.5 \
    libmysqlclient24 \
    libssl3t64 \
    netcat-openbsd \
    tzdata \
    zlib1g && \
  # The Ubuntu 26.04 LTS Docker image has a user called `ubuntu` with UID 1000
  # and GID 1000 by default. Since we allow configuration of the name, UID and
  # GID of the user and group that should be used in the container, we need to
  # either rename the existing user and group or create a new user and group
  # with the specified name, UID and GID.
  cd /tmp && \
  existing_group=$(getent group "$TORTOISE_GROUP_ID") || true && \
  existing_user=$(getent passwd "$TORTOISE_USER_ID") || true && \
  if [ -n "$existing_group" ]; then \
    old_groupname=${existing_group%%:*} && \
    groupmod -n "$TORTOISE_GROUP_NAME" "$old_groupname"; \
  else \
    groupadd -g "$TORTOISE_GROUP_ID" "$TORTOISE_GROUP_NAME"; \
  fi && \
  if [ -n "$existing_user" ]; then \
    old_username=${existing_user%%:*} && \
    usermod -l "$TORTOISE_USER_NAME" -d "/home/$TORTOISE_USER_NAME" "$old_username" && \
    mv "/home/$old_username" "/home/$TORTOISE_USER_NAME"; \
  else \
    useradd -l -u "$TORTOISE_USER_ID" -g "$TORTOISE_GROUP_NAME" -d "/home/$TORTOISE_USER_NAME" -s /bin/sh -m "$TORTOISE_USER_NAME"; \
  fi && \
  # See https://github.com/boxboat/fixuid
  curl -SsL "https://github.com/boxboat/fixuid/releases/download/v0.6.0/fixuid-0.6.0-linux-$TARGETARCH.tar.gz" -o /tmp/fixuid.tar.gz && \
  tar -C /usr/local/bin -xzf /tmp/fixuid.tar.gz && \
  rm /tmp/fixuid.tar.gz && \
  chown root:root /usr/local/bin/fixuid && \
  chmod 4755 /usr/local/bin/fixuid && \
  mkdir -p /etc/fixuid && \
  printf 'user: %s\ngroup: %s\n' "$TORTOISE_USER_NAME" "$TORTOISE_GROUP_NAME" > /etc/fixuid/config.yml && \
  apt remove -y \
    curl && \
  apt autoremove -y && \
  apt clean -y && \
  rm -rf /var/lib/apt/lists/*

# The `etc` directory is not needed at runtime since we provide the
# configuration files via a bind mount.
COPY --from=build --exclude=tortoise/etc* --chown=$TORTOISE_USER_NAME:$TORTOISE_GROUP_NAME /opt /opt

COPY --chmod=755 ./docker/server/docker-cmd-mangosd.sh /usr/local/bin/mangosd
COPY --chmod=755 ./docker/server/docker-cmd-realmd.sh /usr/local/bin/realmd
COPY --chmod=755 ./docker/server/docker-cmd-extract-client-data.sh /usr/local/bin/extract-client-data
COPY --chmod=755 ./docker/server/docker-cmd-verify-client-data.sh /usr/local/bin/verify-client-data

RUN find /opt/tortoise/bin/ -type f ! -name '*.txt' -exec chmod +x {} +

USER $TORTOISE_USER_NAME
WORKDIR "/home/$TORTOISE_USER_NAME"
CMD ["mangosd"]
