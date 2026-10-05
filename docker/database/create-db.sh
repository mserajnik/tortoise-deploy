#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Sets up the databases on the first start, and acknowledges the image's
# migration edits, which a new installation already has.

set -euo pipefail

# shellcheck source=docker/database/db-functions.sh
source "/opt/scripts/db-functions.sh"

clear_database_ready
clear_change_sentinels
mark_initializing

if [[ "${TORTOISE_PROCESS_CUSTOM_SQL:-0}" = "1" ]]; then
  tortoise_log "[x] Custom SQL processing is enabled."
else
  tortoise_log "[ ] Custom SQL processing is disabled."
fi

import_schema "/sql/create_databases.sql"

grant_permissions "tw_world"
grant_permissions "tw_char"
grant_permissions "tw_logon"
grant_permissions "tw_logs"

import_base_data "tw_world" "/sql/base"

configure_realm

ensure_maintenance_db_exists
parse_migration_edits

for i in "${!MIGRATION_EDIT_TARGETS[@]}"; do
  acknowledge_correction "${MIGRATION_EDIT_TARGETS[i]}" "${MIGRATION_EDIT_COMMITS[i]}"
done

mark_initialized

if [[ "${TORTOISE_PROCESS_CUSTOM_SQL:-0}" = "1" ]]; then
  process_custom_sql "/sql/custom"
fi

mark_database_ready
