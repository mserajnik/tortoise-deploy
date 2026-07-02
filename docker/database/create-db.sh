#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Runs once on first container start (via `/docker-entrypoint-initdb.d`) to
# import the schema for the four Tortoise-WoW databases, import the world base
# data, create the application user and seed the realm, then pre-acknowledge
# any baked migration edit so the next start does not re-create the (already
# current) world database. World migrations are applied by the server
# (`mangosd`) at startup, not here.

set -euo pipefail

# shellcheck source=docker/database/db-functions.sh
source "/opt/scripts/db-functions.sh"

clear_database_ready

if [[ "${TORTOISE_PROCESS_CUSTOM_SQL:-0}" = "1" ]]; then
  tortoise_log "[x] Custom SQL processing is enabled."
else
  tortoise_log "[ ] Custom SQL processing is disabled."
fi

# Creates `tw_world`, `tw_char`, `tw_logon` and `tw_logs` with their table
# structures (the dump issues its own `CREATE DATABASE` and `USE` statements).
import_schema "/sql/create_databases.sql"

grant_permissions "tw_world"
grant_permissions "tw_char"
grant_permissions "tw_logon"
grant_permissions "tw_logs"

# Only the world database ships base data; the other three are schema-only.
import_base_data "tw_world" "/sql/base"

configure_realm

if [[ "${TORTOISE_PROCESS_CUSTOM_SQL:-0}" = "1" ]]; then
  process_custom_sql "/sql/custom"
fi

# A fresh install is already at the latest state, so any migration edit baked
# into the image is pre-acknowledged to avoid triggering an unnecessary world
# database re-creation on the next start.
ensure_maintenance_db_exists
parse_migration_edits

if [[ -n "$MIGRATION_EDIT_WORLD" ]]; then
  acknowledge_correction "world" "$MIGRATION_EDIT_WORLD"
fi

mark_database_ready
