# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# shellcheck shell=bash

# Shared helpers sourced by `create-db.sh` and `update-db.sh`: database and
# grant management, schema and base data import, realm seeding, custom SQL
# processing, and migration edit acknowledgement. World migrations are applied
# by the server (`mangosd`) at startup; only the correction (a world database
# re-creation when a migration was edited upstream) happens here.

tortoise_log() {
  echo "[tortoise-deploy]: $*"
}

tortoise_fail() {
  echo "[tortoise-deploy]: ERROR: $*" >&2
  exit 1
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

mark_database_ready() {
  touch /tmp/tortoise-database-ready
}

clear_database_ready() {
  rm -f /tmp/tortoise-database-ready
}

create_database() {
  local db_name="$1"
  local silent="${2:-false}"

  if [[ "$silent" = false ]]; then
    tortoise_log "Creating database '$db_name'..."
  fi

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e \
    "CREATE DATABASE IF NOT EXISTS \`$db_name\` DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_general_ci;"
}

drop_database() {
  local db_name="$1"
  local silent="${2:-false}"

  if [[ "$silent" = false ]]; then
    tortoise_log "Dropping database '$db_name'..."
  fi

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e \
    "DROP DATABASE IF EXISTS \`$db_name\`;"
}

grant_permissions() {
  local db_name="$1"
  local silent="${2:-false}"

  if [[ "$silent" = false ]]; then
    tortoise_log "Granting permissions to database user '$MARIADB_USER' for database '$db_name'..."
  fi

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e \
    "CREATE USER IF NOT EXISTS '$MARIADB_USER'@'%' IDENTIFIED BY '$MARIADB_PASSWORD'; \
    GRANT ALL ON \`$db_name\`.* TO '$MARIADB_USER'@'%'; \
    FLUSH PRIVILEGES;"
}

import_data() {
  local db_name="$1"
  local file="$2"

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$db_name" <"$file"
  return $?
}

# Imports a self-contained schema dump that issues its own `CREATE DATABASE`
# and `USE` statements (such as `create_databases.sql`), so no target database
# is specified.
import_schema() {
  local file="$1"

  tortoise_log "Importing database schema from '$file'..."

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" <"$file"
}

import_base_data() {
  local db_name="$1"
  local file_directory="$2"

  if [[ ! -d "$file_directory" ]]; then
    tortoise_fail "Base data directory '$file_directory' does not exist."
  fi

  shopt -s nullglob
  local files=("$file_directory"/*.sql)
  shopt -u nullglob

  tortoise_log "Importing ${#files[@]} base data file(s) into database '$db_name'..."

  local sql_file
  for sql_file in "${files[@]}"; do
    if ! import_data "$db_name" "$sql_file"; then
      tortoise_fail "Failed to import base data file '$(basename "$sql_file")'."
    fi
  done
}

configure_realm() {
  local realm_name
  local realm_address

  realm_name="$(sql_escape "$TORTOISE_REALMLIST_NAME")"
  realm_address="$(sql_escape "$TORTOISE_REALMLIST_ADDRESS")"
  tortoise_log "Configuring realm '$TORTOISE_REALMLIST_NAME'..."

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "tw_logon" -e \
    "INSERT INTO \`realmlist\` \
       (\`id\`, \`name\`, \`address\`, \`port\`, \`icon\`, \`timezone\`, \`allowedSecurityLevel\`) \
     VALUES \
       (1, '$realm_name', '$realm_address', '$TORTOISE_REALMLIST_PORT', '$TORTOISE_REALMLIST_ICON', '$TORTOISE_REALMLIST_TIMEZONE', '$TORTOISE_REALMLIST_ALLOWED_SECURITY_LEVEL') \
     ON DUPLICATE KEY UPDATE \
       \`name\` = VALUES(\`name\`), \
       \`address\` = VALUES(\`address\`), \
       \`port\` = VALUES(\`port\`), \
       \`icon\` = VALUES(\`icon\`), \
       \`timezone\` = VALUES(\`timezone\`), \
       \`allowedSecurityLevel\` = VALUES(\`allowedSecurityLevel\`);"
}

ensure_maintenance_db_exists() {
  create_database "maintenance" true
  grant_permissions "maintenance" true

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "maintenance" -e \
    "CREATE TABLE IF NOT EXISTS \`migration_corrections\` ( \
      \`db_name\` VARCHAR(64) NOT NULL, \
      \`commit_hash\` CHAR(40) NOT NULL, \
      \`acknowledged_at\` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, \
      PRIMARY KEY (\`db_name\`, \`commit_hash\`) \
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
}

# The `TORTOISE_MIGRATION_EDITS` build argument is baked into
# `/sql/migration-edits` at image build time; manual builds leave the file
# empty and `MIGRATION_EDIT_WORLD` stays empty, which makes the correction a
# no-op.
#
# Leaks the `MIGRATION_EDIT_WORLD` global to the parent script by design;
# `update-db.sh` and `create-db.sh` consume it after sourcing.
# shellcheck disable=SC2034
parse_migration_edits() {
  MIGRATION_EDIT_WORLD=""

  local file="/sql/migration-edits"
  if [[ ! -f "$file" ]]; then
    return 0
  fi

  local raw
  raw="$(head -n1 "$file" | tr -d '\r\n')"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"

  if [[ -z "$raw" ]]; then
    return 0
  fi

  local pair key value
  local saved_ifs="$IFS"
  IFS='|'
  for pair in $raw; do
    IFS="$saved_ifs"
    key="${pair%%:*}"
    value="${pair#*:}"
    case "$key" in
      world) MIGRATION_EDIT_WORLD="$value" ;;
    esac
    IFS='|'
  done
  IFS="$saved_ifs"
}

correction_acknowledged() {
  local db_name="$1"
  local commit_hash="$2"
  local count

  count="$(mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "maintenance" -N -s -e \
    "SELECT COUNT(*) FROM \`migration_corrections\` \
    WHERE \`db_name\` = '$(sql_escape "$db_name")' \
    AND \`commit_hash\` = '$(sql_escape "$commit_hash")';")"

  [[ "$count" -gt 0 ]]
}

acknowledge_correction() {
  local db_name="$1"
  local commit_hash="$2"

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "maintenance" -e \
    "INSERT IGNORE INTO \`migration_corrections\` (\`db_name\`, \`commit_hash\`) \
    VALUES ('$(sql_escape "$db_name")', '$(sql_escape "$commit_hash")');"
}

# Re-creates the world database table structure from `create_databases.sql`.
# That file defines all four databases, so we import only its `tw_world`
# section (plus the dump preamble, which disables foreign key checks and sets
# the session charset) to leave the other three untouched. The base data files
# re-create and populate their own tables on top of this; the remaining
# (DBC-derived) tables are left empty for the server to fill via migrations,
# exactly as on a fresh install.
import_world_schema() {
  tortoise_log "Re-creating world database table structure..."

  awk '
    BEGIN { preamble = 1 }
    /^CREATE DATABASE/ { preamble = 0 }
    preamble { print; next }
    /^USE `tw_world`;/ { world = 1 }
    /^USE `/ && $0 !~ /^USE `tw_world`;/ { world = 0 }
    /^CREATE DATABASE/ { world = 0 }
    world { print }
  ' /sql/create_databases.sql | mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "tw_world"
}

process_world_correction() {
  local commit_hash="$1"

  if [[ -z "$commit_hash" ]]; then
    return 0
  fi

  if correction_acknowledged "world" "$commit_hash"; then
    return 0
  fi

  if [[ "${TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS:-0}" = "1" ]]; then
    tortoise_log "Re-creating world database to apply migration edit (Penqle/tortoise-wow@${commit_hash:0:7})..."
    drop_database "tw_world"
    create_database "tw_world"
    grant_permissions "tw_world"
    import_world_schema
    import_base_data "tw_world" "/sql/base"
    acknowledge_correction "world" "$commit_hash"
    return 0
  fi

  # We deliberately do not record an acknowledgement here so the warning
  # repeats on every start until the user takes action.
  tortoise_log "WARNING: Migration edit detected for the world database (Penqle/tortoise-wow@${commit_hash:0:7}) but 'TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS' is disabled; continuing without correcting it. The server will try to re-apply the edited migration on top of your existing data and may fail to start; re-enable automatic corrections or wipe and re-import the world database to resolve." >&2
}

process_custom_sql() {
  local file_directory="$1"
  local file_count

  if [[ ! -d "$file_directory" ]]; then
    tortoise_log "WARNING: Custom SQL file directory '$file_directory' does not exist." >&2
    return 0
  fi

  if [[ ! -r "$file_directory" ]] || [[ ! -x "$file_directory" ]]; then
    tortoise_fail "Custom SQL file directory '$file_directory' is not readable by the database user (UID $(id -u)). This is a permission problem on the host: the bind-mounted directory must be readable by that user. Adjust the permissions, then restart."
  fi

  file_count=$(find "$file_directory" -name "*.sql" -type f | wc -l)
  tortoise_log "Found $file_count custom SQL file(s) to process."

  if [[ "$file_count" -gt 0 ]]; then
    find "$file_directory" -name "*.sql" -type f | sort | while read -r sql_file; do
      tortoise_log "Processing custom SQL file '$(basename "$sql_file")'..."

      if ! import_data "tw_world" "$sql_file"; then
        tortoise_log "ERROR: Failed to process custom SQL file '$(basename "$sql_file")'." >&2
      fi
    done
  fi
}
