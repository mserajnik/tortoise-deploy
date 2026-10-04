#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Checks the extracted DBC files against the image's hash manifest. Takes the
# DBC directory, by default the one in the extracted data.

set -eu

# shellcheck source=docker/check-deploy-version.sh
. /usr/local/lib/tortoise-deploy/check-deploy-version.sh
# shellcheck source=docker/server/drop-privileges.sh
. /usr/local/lib/tortoise-deploy/drop-privileges.sh

dbc_manifest="/opt/tortoise/dbc-hashes"
dbc_dir="${1:-/opt/tortoise/storage/data/dbc}"

if [ ! -f "$dbc_manifest" ] || [ ! -r "$dbc_manifest" ]; then
  echo "[tortoise-deploy]: ERROR: The DBC hash manifest '$dbc_manifest' is missing or not readable." >&2
  exit 1
fi

# `sha256sum -c` checks only the files a manifest lists, so a truncated one has
# to fail here.
expected_count="$(grep -cE '^[0-9a-fA-F]{64}  ' "$dbc_manifest" || true)"
expected_count="${expected_count:-0}"

if [ "$expected_count" -lt 100 ]; then
  echo "[tortoise-deploy]: ERROR: The DBC hash manifest '$dbc_manifest' lists only $expected_count entries, which is too few for a complete manifest." >&2
  exit 1
fi

if [ ! -d "$dbc_dir" ] || [ ! -r "$dbc_dir" ]; then
  echo "[tortoise-deploy]: ERROR: There is no readable extracted client data in '$dbc_dir'. Mount your extracted data directory at '/opt/tortoise/storage/data' in your 'compose.yaml', as 'compose.yaml.example' shows, or extract the client data first:" >&2
  echo "https://github.com/mserajnik/tortoise-deploy/blob/master/docs/usage.md#extracting-the-client-data" >&2
  exit 1
fi

# The paths in the manifest are relative to the DBC directory.
cd "$dbc_dir"

if ! sha256sum -c --quiet "$dbc_manifest" >&2; then
  echo "[tortoise-deploy]: ERROR: The extracted DBC data in '$dbc_dir' does not match what Tortoise-WoW expects. Extract the data again from the supported client version." >&2
  exit 1
fi

# Look for files the manifest does not list. A client whose archives spell a
# name in two ways gets an identical second copy on a case-sensitive file
# system. The server opens only the manifest's spelling, so that copy passes.
unexpected_count=0

for dbc_file in *.dbc; do
  if [ ! -f "$dbc_file" ]; then
    continue
  fi

  manifest_entry="$(dbc_name="$dbc_file" awk 'tolower($2) == tolower(ENVIRON["dbc_name"]) { print tolower($1), $2; exit }' "$dbc_manifest")"
  manifest_hash="${manifest_entry%% *}"
  manifest_name="${manifest_entry#* }"

  if [ -n "$manifest_entry" ] && [ "$manifest_name" = "$dbc_file" ]; then
    continue
  fi

  # Read from stdin, so `sha256sum` does not escape the file name.
  if [ -n "$manifest_entry" ] && [ "$(sha256sum <"$dbc_file" | cut -d ' ' -f 1)" = "$manifest_hash" ]; then
    echo "[tortoise-deploy]: Ignoring the DBC file '$dbc_file' in '$dbc_dir', which is an identical copy of '$manifest_name'."
    continue
  fi

  echo "[tortoise-deploy]: ERROR: The DBC file '$dbc_file' in '$dbc_dir' is not part of the client Tortoise-WoW supports." >&2
  unexpected_count=$((unexpected_count + 1))
done

if [ "$unexpected_count" -gt 0 ]; then
  echo "[tortoise-deploy]: ERROR: The extracted DBC data in '$dbc_dir' holds files Tortoise-WoW does not expect. Extract the data again from the supported client version." >&2
  exit 1
fi

echo "[tortoise-deploy]: All $expected_count DBC files match what Tortoise-WoW expects."
