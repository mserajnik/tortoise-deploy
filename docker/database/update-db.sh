#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Runs on every subsequent container start (via `/always-initdb.d`) to act on
# baked migration edit metadata, re-seed the realm from the current environment
# and re-apply custom SQL. Migrations themselves are applied by the server
# (`mangosd`) at startup; this acts on any recorded migration edit before the
# database is marked ready.

set -euo pipefail

# shellcheck source=docker/database/db-functions.sh
source "/opt/scripts/db-functions.sh"

clear_database_ready
clear_change_sentinels

if [[ "${TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS:-0}" = "1" ]]; then
  tortoise_log "[x] Automatic world database corrections are enabled."
else
  tortoise_log "[ ] Automatic world database corrections are disabled."
fi

if [[ "${TORTOISE_HALT_ON_MIGRATION_EDITS:-0}" = "1" ]]; then
  tortoise_log "[x] Halting on migration edits is enabled."
else
  tortoise_log "[ ] Halting on migration edits is disabled."
fi

if [[ "${TORTOISE_PROCESS_CUSTOM_SQL:-0}" = "1" ]]; then
  tortoise_log "[x] Custom SQL processing is enabled."
else
  tortoise_log "[ ] Custom SQL processing is disabled."
fi

ensure_maintenance_db_exists
parse_migration_edits

process_world_correction "$MIGRATION_EDIT_WORLD"
process_userstate_correction "character" "$MIGRATION_EDIT_CHARACTER"

if [[ "${#PENDING_DB_NAMES[@]}" -gt 0 ]]; then
  print_correction_abort_message
  wait_for_change_ack

  i=0
  while [[ "$i" -lt "${#PENDING_DB_NAMES[@]}" ]]; do
    acknowledge_correction "${PENDING_DB_NAMES[$i]}" "${PENDING_DB_COMMIT_HASHES[$i]}"
    i=$((i + 1))
  done

  tortoise_log "Migration edits acknowledged; continuing startup."
fi

if [[ "${TORTOISE_PROCESS_CUSTOM_SQL:-0}" = "1" ]]; then
  process_custom_sql "/sql/custom"
fi

configure_realm

mark_database_ready
