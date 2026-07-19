#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Container command wrapper that runs the client data extractors. Skips the
# confirmation prompt when `--force` is passed.

set -eu

eval "$(fixuid -q)"

client_data_dir="/opt/tortoise/storage/client-data"
extracted_data_dir="/opt/tortoise/storage/extracted-data"
extractors_dir="/opt/tortoise/bin"

# The `--force` flag can be used to skip the confirmation prompt when
# previously extracted data is found. This is particularly useful for
# automation where the user is not able to interact with the prompt.
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
  echo "[tortoise-deploy]: ERROR: Client data not found in '$client_data_dir', aborting extraction." >&2
  exit 1
fi

if [ ! -d "$extracted_data_dir" ]; then
  echo "[tortoise-deploy]: ERROR: Extracted data target directory '$extracted_data_dir' does not exist, aborting extraction." >&2
  exit 1
fi

cd "$client_data_dir"

if [ "$force" = false ]; then
  if [ -d "$extracted_data_dir/dbc" ] || [ -d "$extracted_data_dir/maps" ] || [ -d "$extracted_data_dir/mmaps" ] || [ -d "$extracted_data_dir/vmaps" ]; then
    echo "[tortoise-deploy]: Previously extracted data has been found in '$extracted_data_dir'; continue with the extraction (which will overwrite the old data)? [Y/n]"

    if ! read -r choice; then
      choice="y"
    fi
    choice=$(echo "${choice:-y}" | tr -d '[:space:]')
    if [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
      echo "[tortoise-deploy]: Aborting extraction."
      exit 1
    fi
  fi
fi

# Remove any potentially previously extracted data from the client directory.
rm -rf ./Buildings ./dbc ./maps ./mmaps ./vmaps

# `-f 0` keeps terrain heights as full floats; Tortoise-WoW's `mapextractor`
# otherwise quantizes them to integers.
"$extractors_dir/mapextractor" -f 0
# `-l` (high-detail VMap data) is not passed yet: the precise extraction path
# is now fixed upstream, but only on `1181dev` (our `unstable` image), not on
# `main` (`stable`). Enable it once the fix reaches `main`.
"$extractors_dir/vmapextractor"
"$extractors_dir/vmap_assembler"
# `--silent` keeps `MoveMapGen` from blocking on stdin for user input on
# completion or error (it would otherwise hang a non-interactive container).
# With no map arguments it builds all maps using the default filters.
# `--offMeshInput` supplies the hand-authored off-mesh connections (links the
# navmesh generator cannot infer, such as jumps) and `--settingsInput` the
# per-map generation overrides; without them those data files are ignored.
# Vendored from Tortoise-WoW.
# `MoveMapGen` returns 1 on success in `--silent` mode (failures surface as
# shell exit codes above 1), so both 0 and 1 are accepted here while anything
# higher aborts the extraction.
movemap_status=0
"$extractors_dir/MoveMapGen" \
  --silent \
  --offMeshInput "$extractors_dir/offmesh.txt" \
  --settingsInput "$extractors_dir/mmapSettings.txt" || movemap_status=$?
if [ "$movemap_status" -gt 1 ]; then
  echo "[tortoise-deploy]: ERROR: MoveMapGen failed (exit $movemap_status), aborting extraction." >&2
  exit 1
fi

# Delete extracted data that is no longer needed after processing it to avoid
# confusion.
rm -rf ./Buildings

# Remove any potentially already existing data from the extracted data
# directory before moving the new data there. Only the directories we know the
# extractors produce are removed so unrelated files (such as `.gitkeep`) stay
# untouched.
rm -rf \
  "$extracted_data_dir/dbc" \
  "$extracted_data_dir/maps" \
  "$extracted_data_dir/mmaps" \
  "$extracted_data_dir/vmaps"

mv ./dbc ./maps ./mmaps ./vmaps "$extracted_data_dir/"
