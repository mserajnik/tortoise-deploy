#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Container command wrapper for the `mangosd` binary. Drops privileges via
# `fixuid`, validates the bind-mounted configuration files, and launches
# `mangosd`.

set -eu

# Capture the `fixuid -q` exit status first since `eval` discards it.
fixuid_output="$(fixuid -q)"
eval "$fixuid_output"

config_dir="/opt/tortoise/config"
required_files="mangosd.conf"

# `mangosd` exits when a module configuration file is missing or unreadable;
# checking here fails earlier and always names the file. The manifest is
# written at image build time and is absent from images built without modules.
modules_manifest="/opt/tortoise/module-configs"

if [ -f "$modules_manifest" ]; then
  required_files="$required_files
$(sed '/^[[:space:]]*$/d; s|^|modules/|' "$modules_manifest")"
fi

# Read a line at a time rather than leaning on word splitting, so a
# configuration file name containing whitespace still names itself.
while IFS= read -r config_name; do
  [ -n "$config_name" ] || continue

  config_file="$config_dir/$config_name"

  if [ ! -f "$config_file" ] || [ ! -r "$config_file" ]; then
    echo "[tortoise-deploy]: ERROR: Configuration file '$config_file' is missing or not readable, exiting." >&2
    exit 1
  fi
done <<EOF
$required_files
EOF

exec /opt/tortoise/bin/mangosd -c "$config_dir/mangosd.conf"
