# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# shellcheck shell=bash

# Shared helpers sourced by `create-db.sh` and `update-db.sh`: database and
# grant management, schema and base data import, realm seeding, custom SQL
# processing, migration edit acknowledgement, and halt and confirm sentinels.
# Migrations themselves are applied by the server (`mangosd`) at startup; only
# the correction (a world database re-creation) and the halt happen here.

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

clear_change_sentinels() {
  rm -f /tmp/tortoise-changes-pending /tmp/tortoise-changes-acknowledged \
    /tmp/tortoise-changes-consumed
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
# empty and both globals stay empty, which makes every per-database correction
# a no-op.
#
# Leaks the two `MIGRATION_EDIT_*` globals to the parent script by design;
# `update-db.sh` and `create-db.sh` consume them after sourcing.
# shellcheck disable=SC2034
parse_migration_edits() {
  MIGRATION_EDIT_WORLD=""
  MIGRATION_EDIT_CHARACTER=""

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
    # Both parameter expansions below yield the whole token when it holds no
    # colon, which would turn a malformed entry into its own commit hash.
    if [[ "$pair" != *:* ]]; then
      IFS='|'
      continue
    fi
    key="${pair%%:*}"
    value="${pair#*:}"
    case "$key" in
      world) MIGRATION_EDIT_WORLD="$value" ;;
      character) MIGRATION_EDIT_CHARACTER="$value" ;;
    esac
    IFS='|'
  done
  IFS="$saved_ifs"
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

  # This runs as an `if` condition, which suppresses `set -e` for the whole
  # body, so the query status has to be checked by hand. Without it a failed
  # query leaves `count` empty, which reads as a negative result.
  if [[ $status -ne 0 ]]; then
    tortoise_fail "Failed to read the migration correction ledger for '$db_name'."
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

# Extracts the world database table structure from `create_databases.sql`.
# That file defines all four databases, so we take only its `tw_world` section
# (plus the dump preamble, which disables foreign key checks and sets the
# session character set) to leave the other three untouched. The base data
# files re-create and populate their own tables on top of this; the remaining
# (DBC-derived) tables are left empty for the server to fill via migrations,
# exactly as on a fresh install.
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

  tortoise_log "Re-creating world database table structure..."

  mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "tw_world" <<<"$schema"
}

PENDING_DB_NAMES=()
PENDING_DB_COMMIT_HASHES=()

process_world_correction() {
  local commit_hash="$1"
  local schema

  if [[ -z "$commit_hash" ]]; then
    return 0
  fi

  if correction_acknowledged "world" "$commit_hash"; then
    return 0
  fi

  local enable_auto="${TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS:-0}"
  local halt_on_edits="${TORTOISE_HALT_ON_MIGRATION_EDITS:-0}"

  if [[ "$enable_auto" = "1" ]]; then
    # The slice depends only on the dump, so extract it before dropping
    # anything. A failing `awk` then aborts with the existing world database
    # intact instead of leaving an empty one behind.
    schema="$(extract_world_schema)"

    tortoise_log "Re-creating world database to apply migration edit (Penqle/tortoise-wow@${commit_hash:0:7})..."
    drop_database "tw_world"
    create_database "tw_world"
    grant_permissions "tw_world"
    import_world_schema "$schema"
    import_base_data "tw_world" "/sql/base"
    acknowledge_correction "world" "$commit_hash"
    return 0
  fi

  if [[ "$halt_on_edits" = "1" ]]; then
    PENDING_DB_NAMES+=("world")
    PENDING_DB_COMMIT_HASHES+=("$commit_hash")
    return 0
  fi

  # We deliberately do not record an acknowledgement here so the warning
  # repeats on every start until the user takes action.
  tortoise_log "WARNING: Migration edit detected for the world database (Penqle/tortoise-wow@${commit_hash:0:7}) but both 'TORTOISE_ENABLE_AUTOMATIC_WORLD_DB_CORRECTIONS' and 'TORTOISE_HALT_ON_MIGRATION_EDITS' are disabled; continuing without applying or acknowledging. Your world database no longer matches this image and the server may misbehave or fail to start." >&2
}

# The ledger and the baked wire string key on logical target names, but the
# operator acts on the MariaDB database.
correction_database_name() {
  local db_name="$1"

  case "$db_name" in
    world) printf 'tw_world' ;;
    character) printf 'tw_char' ;;
    *) printf '%s' "$db_name" ;;
  esac
}

# A database holding user state cannot be dropped and re-imported the way the
# world database can, so an edit to one of its migrations has no automatic
# remedy at all: the operator applies the SQL by hand and confirms.
process_userstate_correction() {
  local db_name="$1"
  local commit_hash="$2"

  if [[ -z "$commit_hash" ]]; then
    return 0
  fi

  if correction_acknowledged "$db_name" "$commit_hash"; then
    return 0
  fi

  local halt_on_edits="${TORTOISE_HALT_ON_MIGRATION_EDITS:-0}"

  if [[ "$halt_on_edits" = "1" ]]; then
    PENDING_DB_NAMES+=("$db_name")
    PENDING_DB_COMMIT_HASHES+=("$commit_hash")
    return 0
  fi

  # We deliberately do not record an acknowledgement here so the warning
  # repeats on every start until the user takes action.
  tortoise_log "WARNING: Migration edit detected for '$(correction_database_name "$db_name")' database (Penqle/tortoise-wow@${commit_hash:0:7}) but 'TORTOISE_HALT_ON_MIGRATION_EDITS' is disabled; continuing without acknowledging." >&2
}

print_correction_abort_message() {
  cat >&2 <<'EOF'
[tortoise-deploy]: ERROR: Migration edits detected in Tortoise-WoW that affect
the following databases. tortoise-deploy will not apply these changes for you.
Startup is halted.

Affected databases:
EOF

  local i=0
  local name
  local commit_hash
  while [[ "$i" -lt "${#PENDING_DB_NAMES[@]}" ]]; do
    name="${PENDING_DB_NAMES[$i]}"
    commit_hash="${PENDING_DB_COMMIT_HASHES[$i]}"
    printf '  - %s (%s)\n' "$name" "$(correction_database_name "$name")" >&2
    printf '    https://github.com/Penqle/tortoise-wow/commit/%s\n' "$commit_hash" >&2
    i=$((i + 1))
  done

  cat >&2 <<'EOF'

For each affected database:

  1. Open its GitHub link above to see what changed.
  2. Apply the equivalent SQL to the running database yourself, using the name
     in parentheses above:
       docker compose exec database mariadb -u root -p <database>
     (mariadb will prompt for the password; it matches your
     `MARIADB_ROOT_PASSWORD` setting in `compose.yaml`.)

When you have applied the changes to all of them, confirm by running on the
host:
  docker compose exec database tortoise-confirm-changes

To abort instead, run on the host:
  docker compose down

While the container is paused, MariaDB is reachable inside the container via
the internal socket. TCP access on port 3306 is not available during the pause.
Tortoise-WoW stays offline. Nothing restarts on its own; take as long as you
need.

Note: When you confirm, tortoise-deploy treats the listed commits as applied
and continues. It does not check your database to verify that the changes you
made match what the commits describe. If your manual fix is incorrect or
incomplete, the database will be in an inconsistent state and Tortoise-WoW may
fail to start. The responsibility for matching what the commits do is yours;
tortoise-deploy provides no further support for resolving these issues.
EOF
}

wait_for_change_ack() {
  touch /tmp/tortoise-changes-pending

  while [[ ! -f /tmp/tortoise-changes-acknowledged ]]; do
    sleep 5
  done

  rm -f /tmp/tortoise-changes-pending

  # Renamed rather than removed, so `tortoise-confirm-changes` can tell an
  # acknowledgement this pause consumed from one `clear_change_sentinels`
  # deleted on a later start; both make the file disappear.
  mv /tmp/tortoise-changes-acknowledged /tmp/tortoise-changes-consumed
}

process_custom_sql() {
  local file_directory="$1"
  local sql_file
  local sql_files=()
  local sql_files_raw
  local status

  if [[ ! -d "$file_directory" ]]; then
    tortoise_log "WARNING: Custom SQL file directory '$file_directory' does not exist." >&2
    return 0
  fi

  if [[ ! -r "$file_directory" ]] || [[ ! -x "$file_directory" ]]; then
    tortoise_fail "Custom SQL file directory '$file_directory' is not readable by the database user (UID $(id -u)). This is a permission problem on the host: the bind-mounted directory must be readable by that user. Adjust the permissions, then restart."
  fi

  # Collect the listing before the loop rather than piping into it, where a
  # failed `find` would abort with nothing said about which step failed.
  set +e
  sql_files_raw="$(find "$file_directory" -type f -name '*.sql')"
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    tortoise_fail "Failed to list custom SQL files in '$file_directory'."
  fi

  sql_files_raw="$(sort <<<"$sql_files_raw")"
  mapfile -t sql_files < <(printf '%s' "$sql_files_raw")

  tortoise_log "Found ${#sql_files[@]} custom SQL file(s) to process."

  for sql_file in "${sql_files[@]}"; do
    tortoise_log "Processing custom SQL file '$(basename "$sql_file")'..."

    if ! import_data "tw_world" "$sql_file"; then
      tortoise_log "ERROR: Failed to process custom SQL file '$(basename "$sql_file")'." >&2
    fi
  done
}
