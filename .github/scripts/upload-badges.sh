#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Generates the badge JSON files and uploads them via FTP to the static host
# that serves the README badges.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

if [[ -z "${BADGES_FTP_HOST:-}" || -z "${BADGES_FTP_USERNAME:-}" || -z "${BADGES_FTP_PASSWORD:-}" ]]; then
  echo "Badge FTP secrets are missing, skipping upload."
  exit 0
fi

require_env STABLE_COMMIT_HASH
require_env UNSTABLE_COMMIT_HASH

stable_short_hash="${STABLE_COMMIT_HASH:0:7}"
unstable_short_hash="${UNSTABLE_COMMIT_HASH:0:7}"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat >stable-build-badge.json <<EOF
{
  "schemaVersion": 1,
  "label": "Latest stable Tortoise-WoW build",
  "message": "$stable_short_hash",
  "color": "blue"
}
EOF

cat >unstable-build-badge.json <<EOF
{
  "schemaVersion": 1,
  "label": "Latest unstable Tortoise-WoW build",
  "message": "$unstable_short_hash",
  "color": "blue"
}
EOF

cat >date-badge.json <<EOF
{
  "schemaVersion": 1,
  "label": "Latest build date",
  "message": "$timestamp",
  "color": "orange"
}
EOF

curl --fail --silent --show-error \
  -T "{stable-build-badge.json,unstable-build-badge.json,date-badge.json}" \
  --user "$BADGES_FTP_USERNAME:$BADGES_FTP_PASSWORD" \
  "ftp://$BADGES_FTP_HOST/"
