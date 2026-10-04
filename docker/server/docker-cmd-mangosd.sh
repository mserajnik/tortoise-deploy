#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Starts `mangosd`.

set -eu

# shellcheck source=docker/check-deploy-version.sh
. /usr/local/lib/tortoise-deploy/check-deploy-version.sh
# shellcheck source=docker/server/drop-privileges.sh
. /usr/local/lib/tortoise-deploy/drop-privileges.sh

config_dir="/opt/tortoise/config"
required_files="mangosd.conf"

# The build lists the module configuration files here, relative to
# `$config_dir`. An image without modules has no list.
modules_manifest="/opt/tortoise/module-configs"

if [ -f "$modules_manifest" ]; then
  required_files="$required_files
$(sed '/^[[:space:]]*$/d' "$modules_manifest")"
fi

while IFS= read -r config_name; do
  [ -n "$config_name" ] || continue

  config_file="$config_dir/$config_name"

  if [ ! -f "$config_file" ] || [ ! -r "$config_file" ]; then
    echo "[tortoise-deploy]: ERROR: The configuration file '$config_file' is missing or not readable. Your 'compose.yaml' has to mount it from a file on the host, as the 'compose*.yaml.example' files show. If that file did not exist when the container started, Docker created an empty directory in its place. Stop the containers with 'docker compose down', delete that directory on the host, copy the file, and start them again with 'docker compose up -d'." >&2
    exit 1
  fi
done <<EOF
$required_files
EOF

# Data from the wrong client causes faults that look like server bugs.
verify-client-data

exec /opt/tortoise/bin/mangosd -c "$config_dir/mangosd.conf"
