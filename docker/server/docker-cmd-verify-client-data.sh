#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Container command that checks extracted DBC files against the hash manifest
# this image was built with, and refuses data from the wrong game client
# version.
#
# Takes the directory holding the extracted DBC files, and defaults to the
# `dbc` directory inside the bind-mounted extracted data. The extraction
# command passes the directory it has just written, which is still in the
# client data directory.
#
# This script only reads, so it does not need `fixuid` remapping.

set -eu

dbc_manifest="/opt/tortoise/dbc-hashes"
dbc_dir="${1:-/opt/tortoise/storage/extracted-data/dbc}"

# A manifest this script cannot read is a failure of the image. Reporting it
# separately from the floor below points at the right defect.
if [ ! -f "$dbc_manifest" ] || [ ! -r "$dbc_manifest" ]; then
  echo "[tortoise-deploy]: ERROR: The DBC hash manifest '$dbc_manifest' is missing or not readable, exiting." >&2
  exit 1
fi

# The count matches only well-formed entries, so blank padding cannot inflate
# it. `sha256sum -c` skips a blank line without a warning, and the files such a
# manifest leaves out go unhashed.
#
# `grep` exits 1 on zero matches, which `set -e` treats as a failure. The
# `|| true` hands the floor below a count to report.
expected_count="$(grep -cE '^[0-9a-fA-F]{64}  ' "$dbc_manifest" || true)"
expected_count="${expected_count:-0}"

if [ "$expected_count" -lt 100 ]; then
  echo "[tortoise-deploy]: ERROR: The DBC hash manifest '$dbc_manifest' lists $expected_count entries, which is too few for a complete manifest, exiting." >&2
  exit 1
fi

if [ ! -d "$dbc_dir" ] || [ ! -r "$dbc_dir" ]; then
  echo "[tortoise-deploy]: ERROR: The DBC directory '$dbc_dir' is missing or not readable, exiting." >&2
  exit 1
fi

# The comparison runs from inside the directory holding the files, because
# every path in the manifest is relative to it. A directory this user cannot
# enter fails here under `set -e`, ahead of the mismatch check below.
cd "$dbc_dir"

if ! sha256sum -c --quiet "$dbc_manifest" >&2; then
  echo "[tortoise-deploy]: ERROR: The extracted DBC data in '$dbc_dir' does not match what Tortoise-WoW expects. Extract the data again from the supported client version." >&2
  exit 1
fi

# `sha256sum -c` reads only the files the manifest names, so an extra DBC file
# in the extracted set passes the comparison above. The glob runs from inside
# the directory, so it takes no prefix.
actual_count=0

for dbc_file in *.dbc; do
  if [ -f "$dbc_file" ]; then
    actual_count=$((actual_count + 1))
  fi
done

if [ "$actual_count" -ne "$expected_count" ]; then
  echo "[tortoise-deploy]: ERROR: Found $actual_count DBC files in '$dbc_dir' where $expected_count were expected. The extra files are not part of the client Tortoise-WoW supports." >&2
  exit 1
fi

echo "[tortoise-deploy]: All $expected_count DBC files match what Tortoise-WoW expects."
