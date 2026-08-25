# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

ARG DEBIAN_FRONTEND=noninteractive
ARG TORTOISE_REPOSITORY_URL=https://github.com/Penqle/tortoise-wow.git
ARG TORTOISE_REVISION=main
ARG TORTOISE_MODULES=
ARG TORTOISE_MODULE_CONFIGS=
ARG TORTOISE_PATCHES_REPOSITORY_URL
ARG TORTOISE_FAIL_ON_PATCH_ERROR=0
ARG TORTOISE_PATCH_SET=stable
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
ARG TORTOISE_PATCHES_REPOSITORY_URL
ARG TORTOISE_FAIL_ON_PATCH_ERROR
ARG TORTOISE_PATCH_SET

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
    zlib1g-dev && \
  git clone "$TORTOISE_REPOSITORY_URL" /build/core && \
  cd /build/core && \
  git checkout "$TORTOISE_REVISION" && \
  if [ -n "$TORTOISE_PATCHES_REPOSITORY_URL" ]; then \
    echo "Cloning and applying patches from $TORTOISE_PATCHES_REPOSITORY_URL."; \
    git clone "$TORTOISE_PATCHES_REPOSITORY_URL" /build/patches || exit 1; \
    patch_count=0; \
    # Patches in `all` are applied to every build; patches in `<build>` (the
    # `TORTOISE_PATCH_SET` value, `stable` or `unstable`) only to the matching
    # build. All of them apply to `/build/core`. The `<build>` directory is
    # optional and may not exist.
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
    # Bundled modules for the `-modules` image variants, as
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
        # A module's own SQL is read from `TW_SOURCE_MODULES_DIR`, which CMake
        # bakes to a path in this build stage's source tree. That path does not
        # exist in the runtime image and upstream installs the files nowhere,
        # so bundled module SQL would silently never be applied. Refuse the
        # build instead of shipping it.
        if [ -d "$module_path/data/sql" ] && \
          [ -n "$(find -L "$module_path/data/sql" -xdev ! -type d \
            -iname '*.sql' -print -quit)" ]; then \
          echo "Module '$module_directory' ships SQL in 'data/sql/', which this image cannot apply."; \
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
    # Record the module configuration files `mangosd` insists on at startup so
    # the container command can name a missing one. The names come from what
    # upstream installed, built from the same `conf/*.conf.dist` glob as the
    # list compiled into the binary; `etc/` does not reach the runtime image,
    # so the list has to be carried out of it. A module need not ship a
    # configuration file at all, hence the guard on the glob matching.
    for module_config_dist in /opt/tortoise/etc/modules/*.conf.dist; do \
      if [ -f "$module_config_dist" ]; then \
        basename "$module_config_dist" .dist; \
      fi; \
    done >/opt/tortoise/module-configs; \
    # The comparison below is a string compare, so both sides have to agree on
    # order. Sorting in the C locale matches what `prepare-image-build.sh`
    # emits, whatever locale it happens to run under.
    LC_ALL=C sort -o /opt/tortoise/module-configs /opt/tortoise/module-configs; \
    # Refuse to publish an image that demands a configuration file the
    # repository ships no example for. Module code floats, so a module can add
    # or rename a template between builds, and either would make every variant
    # container exit on startup for want of a bind mount nobody knew to add.
    # `TORTOISE_MODULE_CONFIGS` is derived from `config/modules/`, so the two
    # agree only while the shipped examples cover exactly what the build needs.
    # This also catches an empty list, which would otherwise leave the startup
    # check with nothing to verify.
    installed_module_configs="$(tr '\n' ',' </opt/tortoise/module-configs)"; \
    if [ "${installed_module_configs%,}" != "$TORTOISE_MODULE_CONFIGS" ]; then \
      echo "This build requires the module configuration files '${installed_module_configs%,}', but the repository ships examples for '$TORTOISE_MODULE_CONFIGS'."; \
      exit 1; \
    fi; \
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
    /opt/tortoise/bin/

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

RUN find /opt/tortoise/bin/ -type f ! -name '*.txt' -exec chmod +x {} +

USER $TORTOISE_USER_NAME
WORKDIR "/home/$TORTOISE_USER_NAME"
CMD ["mangosd"]
