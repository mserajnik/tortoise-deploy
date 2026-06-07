# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

ARG DEBIAN_FRONTEND=noninteractive
ARG TORTOISE_REPOSITORY_URL=https://github.com/Penqle/tortoise-wow.git
ARG TORTOISE_REVISION=main
ARG TORTOISE_PATCHES_REPOSITORY_URL
ARG TORTOISE_FAIL_ON_PATCH_ERROR=0
ARG TORTOISE_PATCH_SET=stable
ARG TORTOISE_APPLY_CUSTOMIZED=0
ARG TORTOISE_USER_ID=1000
ARG TORTOISE_GROUP_ID=1000
ARG TORTOISE_USER_NAME=tortoise
ARG TORTOISE_GROUP_NAME=tortoise

FROM ubuntu:26.04 AS build

ARG DEBIAN_FRONTEND
ARG TORTOISE_REPOSITORY_URL
ARG TORTOISE_REVISION
ARG TORTOISE_PATCHES_REPOSITORY_URL
ARG TORTOISE_FAIL_ON_PATCH_ERROR
ARG TORTOISE_PATCH_SET
ARG TORTOISE_APPLY_CUSTOMIZED

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
    echo "Cloning and applying patches from $TORTOISE_PATCHES_REPOSITORY_URL"; \
    git clone "$TORTOISE_PATCHES_REPOSITORY_URL" /build/patches && \
    patch_count=0 && \
    # Patches in `all` are applied to every build; patches in `<build>` (the
    # `TORTOISE_PATCH_SET` value, `stable` or `unstable`) only to the matching
    # build; patches in `customized` only to the `:customized` build. All of
    # them apply to `/build/core`. The `<build>` and `customized` directories
    # are optional and may not exist.
    customized_patches="" && \
    if [ "$TORTOISE_APPLY_CUSTOMIZED" = "1" ]; then \
      customized_patches="/build/patches/customized/*.patch"; \
    fi && \
    for patch in \
      /build/patches/all/*.patch \
      /build/patches/$TORTOISE_PATCH_SET/*.patch \
      $customized_patches; \
    do \
      if [ -f "$patch" ]; then \
        echo "Applying patch $patch"; \
        if ! git apply "$patch"; then \
          echo "Failed to apply patch $patch"; \
          if [ "$TORTOISE_FAIL_ON_PATCH_ERROR" = "1" ]; then \
            exit 1; \
          fi; \
        fi; \
        patch_count=$((patch_count + 1)); \
      fi; \
    done; \
    if [ $patch_count -eq 0 ]; then \
      echo "No patches found"; \
    fi; \
  else \
    echo "No repository to apply patches from provided"; \
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
    -DALLOW_TURTLE_ADDONS=ON \
    -DUSE_EXTRACTORS=ON \
    -DDEBUG_SYMBOLS=0 && \
  make -j"$(nproc)" && \
  make install && \
  # Stage the world migrations so `mangosd` can apply them at startup. The
  # vendored `mangosd.conf` sets `Database.AutoUpdate.Path` to
  # `/opt/tortoise/sql/`, and the applier reads world migrations from
  # `<Path>/database_updates`.
  mkdir -p /opt/tortoise/sql && \
  cp -r /build/core/sql/database_updates /opt/tortoise/sql/database_updates && \
  # `MoveMapGen` needs these data files passed explicitly (see the extraction
  # command wrapper); Tortoise-WoW's build installs only the binary, so we
  # stage them alongside it.
  cp \
    /build/core/tools/mmap/offmesh.txt \
    /build/core/tools/mmap/mmapSettings.txt \
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
    old_groupname=$(echo "$existing_group" | cut -d':' -f1) && \
    groupmod -n "$TORTOISE_GROUP_NAME" "$old_groupname"; \
  else \
    groupadd -g "$TORTOISE_GROUP_ID" "$TORTOISE_GROUP_NAME"; \
  fi && \
  if [ -n "$existing_user" ]; then \
    old_username=$(echo "$existing_user" | cut -d':' -f1) && \
    usermod -l "$TORTOISE_USER_NAME" -d "/home/$TORTOISE_USER_NAME" "$old_username" && \
    mv "/home/$old_username" "/home/$TORTOISE_USER_NAME"; \
  else \
    useradd -u "$TORTOISE_USER_ID" -g "$TORTOISE_GROUP_NAME" -d "/home/$TORTOISE_USER_NAME" -s /bin/sh -m "$TORTOISE_USER_NAME"; \
  fi && \
  # See https://github.com/boxboat/fixuid
  curl -SsL "https://github.com/boxboat/fixuid/releases/download/v0.6.0/fixuid-0.6.0-linux-$TARGETARCH.tar.gz" | tar -C /usr/local/bin -xzf - && \
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
