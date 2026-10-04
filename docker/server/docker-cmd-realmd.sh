#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Starts `realmd`.

set -eu

# shellcheck source=docker/check-deploy-version.sh
. /usr/local/lib/tortoise-deploy/check-deploy-version.sh
# shellcheck source=docker/server/drop-privileges.sh
. /usr/local/lib/tortoise-deploy/drop-privileges.sh

config_file="/opt/tortoise/config/realmd.conf"

if [ ! -f "$config_file" ] || [ ! -r "$config_file" ]; then
  echo "[tortoise-deploy]: ERROR: The configuration file '$config_file' is missing or not readable. Your 'compose.yaml' has to mount it from a file on the host, as the 'compose*.yaml.example' files show. If that file did not exist when the container started, Docker created an empty directory in its place. Stop the containers with 'docker compose down', delete that directory on the host, copy the file, and start them again with 'docker compose up -d'." >&2
  exit 1
fi

exec /opt/tortoise/bin/realmd -c "$config_file"
