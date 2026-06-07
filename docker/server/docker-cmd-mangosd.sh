#!/bin/sh

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Container command wrapper for the `mangosd` binary. Drops privileges via
# `fixuid`, validates the bind-mounted config file, and launches `mangosd`.

set -eu

eval "$(fixuid -q)"

config_file="/opt/tortoise/config/mangosd.conf"

if [ ! -f "$config_file" ]; then
  echo "[tortoise-deploy]: ERROR: Configuration file '$config_file' is missing, exiting." >&2
  exit 1
fi

exec /opt/tortoise/bin/mangosd -c "$config_file"
