#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Runs on every subsequent container start (via `/always-initdb.d`) to apply
# any world database migration-edit correction, re-seed the realm from the
# current environment and re-apply custom SQL. World migrations themselves are
# applied by the server (`mangosd`) at startup; only the correction (a world
# database re-creation when a migration was edited upstream) happens here.

set -euo pipefail

# shellcheck source=docker/database/db-functions.sh
source "/opt/scripts/db-functions.sh"

clear_database_ready

if [[ "${TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS:-0}" = "1" ]]; then
  tortoise_log "[x] Automatic world database corrections are enabled."
else
  tortoise_log "[ ] Automatic world database corrections are disabled."
fi

if [[ "${TORTOISE_PROCESS_CUSTOM_SQL:-0}" = "1" ]]; then
  tortoise_log "[x] Custom SQL processing is enabled."
else
  tortoise_log "[ ] Custom SQL processing is disabled."
fi

ensure_maintenance_db_exists
parse_migration_edits
process_world_correction "$MIGRATION_EDIT_WORLD"

if [[ "${TORTOISE_PROCESS_CUSTOM_SQL:-0}" = "1" ]]; then
  process_custom_sql "/sql/custom"
fi

configure_realm

mark_database_ready
