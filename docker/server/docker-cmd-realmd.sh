#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Container command wrapper for the `realmd` binary. Drops privileges via
# `fixuid`, validates the bind-mounted configuration file, and launches
# `realmd`.

set -eu

# Capture the `fixuid -q` exit status first since `eval` discards it.
fixuid_output="$(fixuid -q)"
eval "$fixuid_output"

config_file="/opt/tortoise/config/realmd.conf"

if [ ! -f "$config_file" ] || [ ! -r "$config_file" ]; then
  echo "[tortoise-deploy]: ERROR: Configuration file '$config_file' is missing or not readable, exiting." >&2
  exit 1
fi

exec /opt/tortoise/bin/realmd -c "$config_file"
