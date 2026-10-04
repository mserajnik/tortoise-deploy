# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# shellcheck shell=bash

# Helpers for `create-db.sh` and `update-db.sh`. `mangosd` applies the
# migrations itself.

tortoise_log() {
  echo "[tortoise-deploy]: $*"
}

tortoise_fail() {
  echo "[tortoise-deploy]: ERROR: $*" >&2
  exit 1
}

sql_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

mark_database_ready() {
  touch /tmp/tortoise-database-ready
}

clear_database_ready() {
  rm -f /tmp/tortoise-database-ready
}

clear_change_sentinels() {
  rm -f /tmp/tortoise-changes-pending /tmp/tortoise-changes-acknowledged
}

# A data directory with the first marker is from a first start that did not
# finish.
INITIALIZING_MARKER="/var/lib/mysql/.tortoise-deploy-initializing"
INITIALIZED_MARKER="/var/lib/mysql/.tortoise-deploy-initialized"

mark_initializing() {
  touch "$INITIALIZING_MARKER"
}

mark_initialized() {
  mv "$INITIALIZING_MARKER" "$INITIALIZED_MARKER"
}

# A data directory from before the markers counts as set up when its world
# database holds data.
require_initialized() {
  if [[ -f "$INITIALIZED_MARKER" ]]; then
    return 0
  fi

  if [[ ! -f "$INITIALIZING_MARKER" ]] &&
    mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -s -e \
      "SELECT 1 FROM \`tw_world\`.\`creature_template\` LIMIT 1;" |
    grep -q 1; then
    touch "$INITIALIZED_MARKER"
    return 0
  fi

  tortoise_fail "The databases are not set up completely. If this is a new installation, remove the database volume and start again. Otherwise the volume holds your characters: remove it only if you have a backup, and restore the backup after the new start:
https://github.com/mserajnik/tortoise-deploy/blob/master/docs/usage.md#restoring-a-backup"
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
  local user
  local password

  if [[ "$silent" = false ]]; then
    tortoise_log "Granting permissions to database user '$MARIADB_USER' for database '$db_name'..."
  fi

  user="$(sql_escape "$MARIADB_USER")"
  password="$(sql_escape "$MARIADB_PASSWORD")"

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e \
    "CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$password'; \
    GRANT ALL ON \`$db_name\`.* TO '$user'@'%'; \
    FLUSH PRIVILEGES;"
}

import_data() {
  local db_name="$1"
  local file="$2"

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$db_name" <"$file"
  return $?
}

# Imports a dump that creates and selects its databases itself.
import_schema() {
  local file="$1"

  tortoise_log "Importing database schema from '$file'..."

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" <"$file"
}

import_base_data() {
  local db_name="$1"
  local file_directory="$2"

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
  local realm_port
  local realm_icon
  local realm_timezone
  local realm_allowed_security_level

  realm_name="$(sql_escape "$TORTOISE_REALMLIST_NAME")"
  realm_address="$(sql_escape "$TORTOISE_REALMLIST_ADDRESS")"
  realm_port="$(sql_escape "$TORTOISE_REALMLIST_PORT")"
  realm_icon="$(sql_escape "$TORTOISE_REALMLIST_ICON")"
  realm_timezone="$(sql_escape "$TORTOISE_REALMLIST_TIMEZONE")"
  realm_allowed_security_level="$(sql_escape "$TORTOISE_REALMLIST_ALLOWED_SECURITY_LEVEL")"
  tortoise_log "Configuring realm '$TORTOISE_REALMLIST_NAME'..."

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "tw_logon" -e \
    "INSERT INTO \`realmlist\` \
       (\`id\`, \`name\`, \`address\`, \`port\`, \`icon\`, \`timezone\`, \`allowedSecurityLevel\`) \
     VALUES \
       (1, '$realm_name', '$realm_address', '$realm_port', '$realm_icon', '$realm_timezone', '$realm_allowed_security_level') \
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

# The GitHub repository of a migration edit source.
correction_source_repository() {
  local source_name="$1"

  case "$source_name" in
    core) printf 'tortoise-wow/tortoise-wow' ;;
    tortoisebots) printf 'Sagiroth/TortoiseBots' ;;
    *) tortoise_fail "The list of migration edits in this image is damaged (unknown source '$source_name'). Report it:
https://github.com/mserajnik/tortoise-deploy/issues" ;;
  esac
}

# Reads `/sql/migration-edits`, which the build writes from
# `TORTOISE_MIGRATION_EDITS`, into the `MIGRATION_EDIT_*` arrays, one element
# per edit. The value is `<target>:<source>@<commit>[,<source>@<commit>]...`
# entries separated by `|`. A manual build leaves the file empty.
parse_migration_edits() {
  MIGRATION_EDIT_TARGETS=()
  MIGRATION_EDIT_SOURCES=()
  MIGRATION_EDIT_COMMITS=()

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

  local entry target sources token
  local entries=() tokens=()

  IFS='|' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    if [[ "$entry" != *:* ]]; then
      tortoise_fail "The list of migration edits in this image is damaged ('$entry'). Report it:
https://github.com/mserajnik/tortoise-deploy/issues"
    fi
    target="${entry%%:*}"
    sources="${entry#*:}"

    IFS=',' read -r -a tokens <<<"$sources"
    for token in "${tokens[@]}"; do
      if [[ "$token" != *@* ]]; then
        tortoise_fail "The list of migration edits in this image is damaged ('$token'). Report it:
https://github.com/mserajnik/tortoise-deploy/issues"
      fi
      MIGRATION_EDIT_TARGETS+=("$target")
      MIGRATION_EDIT_SOURCES+=("${token%%@*}")
      MIGRATION_EDIT_COMMITS+=("${token#*@}")
    done
  done
}

correction_acknowledged() {
  local db_name="$1"
  local commit_hash="$2"
  local count
  local status

  set +e
  count="$(mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "maintenance" -N -s -e \
    "SELECT COUNT(*) FROM \`migration_corrections\` \
    WHERE \`db_name\` = '$(sql_escape "$db_name")' \
    AND \`commit_hash\` = '$(sql_escape "$commit_hash")';")"
  status=$?
  set -e

  # Callers use this as a condition, where `set -e` does not apply, so check
  # the query status by hand.
  if [[ $status -ne 0 ]]; then
    tortoise_fail "Failed to read which migration edits the databases have applied. See the error above."
  fi

  [[ "$count" -gt 0 ]]
}

acknowledge_correction() {
  local db_name="$1"
  local commit_hash="$2"

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "maintenance" -e \
    "INSERT IGNORE INTO \`migration_corrections\` (\`db_name\`, \`commit_hash\`) \
    VALUES ('$(sql_escape "$db_name")', '$(sql_escape "$commit_hash")');"
}

# The `tw_world` part of `create_databases.sql`, with the dump's preamble. The
# base data fills some of its tables, and `mangosd` fills the rest, as on a
# fresh install.
extract_world_schema() {
  awk '
    BEGIN { preamble = 1 }
    /^CREATE DATABASE/ { preamble = 0 }
    preamble { print; next }
    /^USE `tw_world`;/ { world = 1 }
    /^USE `/ && $0 !~ /^USE `tw_world`;/ { world = 0 }
    /^CREATE DATABASE/ { world = 0 }
    world { print }
  ' /sql/create_databases.sql
}

import_world_schema() {
  local schema="$1"

  tortoise_log "Re-creating the world database table structure..."

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "tw_world" <<<"$schema"
}

# Re-creates the world database from the image's SQL, which already contains
# every migration edit.
recreate_world_database() {
  local schema use_count world_use_count

  # Check the slice before dropping anything. It has to hold tables, and every
  # `USE` in it has to select `tw_world`: from a dump without `CREATE DATABASE`
  # lines, it would contain all four databases.
  schema="$(extract_world_schema)"
  use_count="$(grep -ciE '^[[:space:]]*use([^a-z0-9_$]|$)' <<<"$schema" || true)"
  # shellcheck disable=SC2016
  world_use_count="$(grep -c '^USE `tw_world`;' <<<"$schema" || true)"

  # shellcheck disable=SC2016
  if ! grep -q '^CREATE TABLE' <<<"$schema" ||
    ! grep -q '^USE `tw_world`;' <<<"$schema" ||
    [[ "$use_count" -ne "$world_use_count" ]]; then
    tortoise_fail "This image cannot re-create the world database. The world database is unchanged. Report it:
https://github.com/mserajnik/tortoise-deploy/issues"
  fi

  drop_database "tw_world"
  create_database "tw_world"
  grant_permissions "tw_world"
  import_world_schema "$schema"
  import_base_data "tw_world" "/sql/base"
}

PENDING_DB_NAMES=()
PENDING_DB_SOURCES=()
PENDING_DB_COMMIT_HASHES=()

# One re-creation applies every pending world edit at once.
process_world_corrections() {
  local i
  local pending=()

  for i in "${!MIGRATION_EDIT_TARGETS[@]}"; do
    if [[ "${MIGRATION_EDIT_TARGETS[i]}" = "world" ]] &&
      ! correction_acknowledged "world" "${MIGRATION_EDIT_COMMITS[i]}"; then
      pending+=("$i")
    fi
  done

  if [[ "${#pending[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS:-0}" = "1" ]]; then
    tortoise_log "Re-creating the world database to apply the migration edits..."
    recreate_world_database
    for i in "${pending[@]}"; do
      acknowledge_correction "world" "${MIGRATION_EDIT_COMMITS[i]}"
    done
    return 0
  fi

  if [[ "${TORTOISE_HALT_ON_MIGRATION_EDITS:-0}" = "1" ]]; then
    for i in "${pending[@]}"; do
      PENDING_DB_NAMES+=("world")
      PENDING_DB_SOURCES+=("${MIGRATION_EDIT_SOURCES[i]}")
      PENDING_DB_COMMIT_HASHES+=("${MIGRATION_EDIT_COMMITS[i]}")
    done
    return 0
  fi

  # Leave the edit unacknowledged. The warning then repeats on every start.
  local repository
  for i in "${pending[@]}"; do
    repository="$(correction_source_repository "${MIGRATION_EDIT_SOURCES[i]}")"
    tortoise_log "WARNING: The world database has a migration edit ($repository@${MIGRATION_EDIT_COMMITS[i]:0:7}), but both 'TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS' and 'TORTOISE_HALT_ON_MIGRATION_EDITS' are disabled. The start continues, and the world database stays out of step with this image. The server may misbehave or fail to start." >&2
  done
}

# The MariaDB database of a migration edit target.
correction_database_name() {
  local db_name="$1"

  case "$db_name" in
    world) printf 'tw_world' ;;
    character) printf 'tw_char' ;;
    *) tortoise_fail "The list of migration edits in this image is damaged (unknown target '$db_name'). Report it:
https://github.com/mserajnik/tortoise-deploy/issues" ;;
  esac
}

# A database with user state cannot be re-created. The user applies its edits
# by hand and confirms.
process_userstate_corrections() {
  local i db_name source_name commit_hash repository database_name

  for i in "${!MIGRATION_EDIT_TARGETS[@]}"; do
    db_name="${MIGRATION_EDIT_TARGETS[i]}"
    source_name="${MIGRATION_EDIT_SOURCES[i]}"
    commit_hash="${MIGRATION_EDIT_COMMITS[i]}"

    if [[ "$db_name" = "world" ]] ||
      correction_acknowledged "$db_name" "$commit_hash"; then
      continue
    fi

    if [[ "${TORTOISE_HALT_ON_MIGRATION_EDITS:-0}" = "1" ]]; then
      PENDING_DB_NAMES+=("$db_name")
      PENDING_DB_SOURCES+=("$source_name")
      PENDING_DB_COMMIT_HASHES+=("$commit_hash")
      continue
    fi

    # Leave the edit unacknowledged. The warning then repeats on every start.
    repository="$(correction_source_repository "$source_name")"
    database_name="$(correction_database_name "$db_name")"
    tortoise_log "WARNING: The '$database_name' database has a migration edit ($repository@${commit_hash:0:7}), but 'TORTOISE_HALT_ON_MIGRATION_EDITS' is disabled. The start continues, and the database stays out of step with this image." >&2
  done
}

print_correction_abort_message() {
  cat >&2 <<'EOF'
[tortoise-deploy]: ERROR: Migration edits affect your databases.
tortoise-deploy will not apply these changes for you. Startup is halted.

Affected databases, one entry per edit:
EOF

  local i=0
  local name
  local source_name
  local commit_hash
  local repository
  local database_name
  while [[ "$i" -lt "${#PENDING_DB_NAMES[@]}" ]]; do
    name="${PENDING_DB_NAMES[$i]}"
    source_name="${PENDING_DB_SOURCES[$i]}"
    commit_hash="${PENDING_DB_COMMIT_HASHES[$i]}"
    repository="$(correction_source_repository "$source_name")"
    database_name="$(correction_database_name "$name")"
    printf '  - %s (%s)\n' "$name" "$database_name" >&2
    printf '    https://github.com/%s/commit/%s\n' "$repository" "$commit_hash" >&2
    i=$((i + 1))
  done

  cat >&2 <<'EOF'

For each entry above:

  1. Open its GitHub link to see what changed.
  2. Apply the equivalent SQL to the running database yourself, using the name
     in parentheses above:
       docker compose exec database mariadb -u root -p <database>
     (mariadb prompts for the password, which matches your
     'MARIADB_ROOT_PASSWORD' setting in your 'compose.yaml'.)

When you have applied the changes to all of them, confirm by running on the
host:
  docker compose exec database tortoise-confirm-changes

To abort instead, run on the host:
  docker compose down

While the container is paused, MariaDB is reachable inside the container via
the internal socket. TCP access on port 3306 is not available during the pause.
Tortoise-WoW stays offline until you confirm or abort, so take as long as you
need.

Note: When you confirm, tortoise-deploy treats the listed commits as applied
and continues. It does not check your database to verify that the changes you
made match what the commits describe. If your manual fix is incorrect or
incomplete, the database will be in an inconsistent state and Tortoise-WoW may
fail to start. The responsibility for matching what the commits do is yours,
and tortoise-deploy provides no further support for resolving these issues.
EOF
}

wait_for_change_ack() {
  touch /tmp/tortoise-changes-pending

  while [[ ! -f /tmp/tortoise-changes-acknowledged ]]; do
    sleep 5
  done

  rm -f /tmp/tortoise-changes-pending

  # `tortoise-confirm-changes` waits for the receipt, because a later start
  # deletes the acknowledgement too.
  mv /tmp/tortoise-changes-acknowledged /tmp/tortoise-changes-consumed
}

process_custom_sql() {
  local file_directory="$1"
  local sql_file
  local sql_files=()
  local sql_files_raw
  local status

  if [[ ! -d "$file_directory" ]]; then
    tortoise_log "WARNING: The custom SQL file directory '$file_directory' does not exist." >&2
    return 0
  fi

  if [[ ! -r "$file_directory" ]] || [[ ! -x "$file_directory" ]]; then
    tortoise_fail "The custom SQL file directory '$file_directory' is not readable by the database user (UID $(id -u)). This is a permission problem on the host: the bind-mounted directory must be readable by that user. Adjust the permissions, then restart."
  fi

  # Check `find` on its own, so a failure says which step failed. The names are
  # passed through a file, because a command substitution drops NUL bytes.
  sql_files_raw="$(mktemp)"
  set +e
  find "$file_directory" -type f -name '*.sql' -print0 >"$sql_files_raw"
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    rm -f "$sql_files_raw"
    tortoise_fail "Failed to list custom SQL files in '$file_directory'."
  fi

  set +e
  sort -z -o "$sql_files_raw" "$sql_files_raw"
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    rm -f "$sql_files_raw"
    tortoise_fail "Failed to sort the custom SQL file listing in '$file_directory'."
  fi

  mapfile -d '' -t sql_files <"$sql_files_raw"
  rm -f "$sql_files_raw"

  tortoise_log "Found ${#sql_files[@]} custom SQL file(s) to process."

  for sql_file in "${sql_files[@]}"; do
    tortoise_log "Processing custom SQL file '$(basename "$sql_file")'..."

    if ! import_data "tw_world" "$sql_file"; then
      tortoise_log "ERROR: Failed to process custom SQL file '$(basename "$sql_file")'." >&2
    fi
  done
}
