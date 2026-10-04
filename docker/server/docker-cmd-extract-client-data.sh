#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Runs the client data extractors. `--force` skips the prompt about existing
# data.

set -eu

# shellcheck source=docker/check-deploy-version.sh
. /usr/local/lib/tortoise-deploy/check-deploy-version.sh
# shellcheck source=docker/server/drop-privileges.sh
. /usr/local/lib/tortoise-deploy/drop-privileges.sh

client_data_dir="/opt/tortoise/storage/client-data"
extracted_data_dir="/opt/tortoise/storage/data"
extractors_dir="/opt/tortoise/bin"

extraction_failed() {
  echo "[tortoise-deploy]: ERROR: The extraction failed. See the errors above." >&2
  exit 1
}

force=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f | --force)
      force=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ ! -d "$client_data_dir" ] || [ ! -d "$client_data_dir/Data" ]; then
  echo "[tortoise-deploy]: ERROR: '$client_data_dir' has no 'Data' directory. Copy the contents of your client directory there." >&2
  exit 1
fi

if [ ! -d "$extracted_data_dir" ]; then
  echo "[tortoise-deploy]: ERROR: The extracted data directory '$extracted_data_dir' does not exist. Mount your extracted data directory there in your 'compose.yaml', as 'compose.yaml.example' shows." >&2
  exit 1
fi

# The extractors write into the working directory.
cd "$client_data_dir"

if [ "$force" = false ]; then
  if [ -d "$extracted_data_dir/dbc" ] || [ -d "$extracted_data_dir/maps" ] || [ -d "$extracted_data_dir/mmaps" ] || [ -d "$extracted_data_dir/vmaps" ]; then
    echo "[tortoise-deploy]: Previously extracted data has been found in '$extracted_data_dir'. Continue with the extraction, which will overwrite the old data? [Y/n]"

    if ! read -r choice; then
      choice="y"
    fi
    choice=$(echo "${choice:-y}" | tr -d '[:space:]')
    if [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
      echo "[tortoise-deploy]: The old data stays in place."
      exit 1
    fi
  fi
fi

# Remove the output of an earlier run.
rm -rf ./Buildings ./dbc ./maps ./mmaps ./vmaps

# `-f 0` keeps terrain heights as full floats; Tortoise-WoW's `mapextractor`
# otherwise quantizes them to integers.
"$extractors_dir/mapextractor" -f 0 || extraction_failed
# `mapextractor` also returns 0 when it cannot write into the working
# directory.
if [ ! -d ./dbc ]; then
  extraction_failed
fi

# Stop on data from an unsupported client before the slow VMap and MMap steps.
verify-client-data "$client_data_dir/dbc"

# `-l` extracts the full WMO geometry, which makes the VMaps more precise.
"$extractors_dir/vmapextractor" -l || extraction_failed
"$extractors_dir/vmap_assembler" || extraction_failed
# `--silent` keeps `MoveMapGen` from waiting for input. In that mode it returns
# 1 on success, so only a higher status is a failure.
movemap_status=0
"$extractors_dir/MoveMapGen" \
  --silent \
  --offMeshInput "$extractors_dir/offmesh.txt" \
  --settingsInput "$extractors_dir/mmapSettings.txt" || movemap_status=$?
if [ "$movemap_status" -gt 1 ]; then
  extraction_failed
fi

# Remove what the server does not need.
rm -rf ./Buildings

# Replace only what the extractors produce, so files such as `.gitkeep` stay.
rm -rf \
  "$extracted_data_dir/dbc" \
  "$extracted_data_dir/maps" \
  "$extracted_data_dir/mmaps" \
  "$extracted_data_dir/vmaps"

# `dbc/` moves last. After an interrupted move, the DBC files are missing, and
# the server refuses to start.
mv ./maps ./mmaps ./vmaps ./dbc "$extracted_data_dir/"
