#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Compares pinned upstream references against the resolved upstream `HEAD`.
# Sources are opt-in: each source's checks run only when its environment
# variables (`*_REPOSITORY`, `*_LATEST_COMMIT_HASH`, `*_KNOWN_COMMIT_HASH`) are
# provided. Fails the workflow when any reference has drifted so the matching
# local files can be reviewed.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Each entry: <description>|<known_url>|<latest_url>.
declare -a checks=()

# Fetches one reference, reporting which check failed and why it plausibly did.
fetch_reference() {
  local url="$1"
  local destination="$2"
  local desc="$3"

  if ! curl --fail --silent --show-error --location --output "$destination" "$url"; then
    fail "Could not fetch $url for '$desc'. A watched path that stops resolving has usually been renamed or removed upstream; review it and update the path here."
  fi
}

add_github_check() {
  local owner_repo="$1"
  local known_commit_hash="$2"
  local latest_commit_hash="$3"
  local path="$4"
  local label="${5:-}"

  local desc="$owner_repo${label:+@$label}:$path"
  local known_url="https://raw.githubusercontent.com/$owner_repo/$known_commit_hash/$path"
  local latest_url="https://raw.githubusercontent.com/$owner_repo/$latest_commit_hash/$path"

  checks+=("$desc|$known_url|$latest_url")
}

# `sql/create_databases.sql` is watched because `extract_world_schema` (in
# `db-functions.sh`) isolates its `tw_world` section with format-sensitive awk
# anchors (the dump preamble and the `CREATE DATABASE` / `USE` lines); a
# regenerated dump in a different format (e.g. an upstream database rebase)
# would silently mis-extract, and this check is what catches that before an
# image is built.
#
# `sql/base/tw_world_migrations.sql` is the one base dump
# `compute-migration-edits.sh` deliberately ignores. It only dumps the
# auto-updater's bookkeeping table rather than world data, so a change to it is
# surfaced here for review.
#
# The configuration files we mirror as `*.conf.example` and the top-level
# `CMakeLists.txt` are watched too; the latter is where new `find_package(...)`
# would typically introduce a new dependency that we would need to install.
#
# Files we only patch (such as `AutoUpdater.cpp`) are not watched here: a drift
# that breaks a patch already fails the build via
# `TORTOISE_FAIL_ON_PATCH_ERROR`.
#
# Tortoise-WoW is built from two branches (`main` and `1181dev`) that can
# diverge, so each is checked against its own pinned commit.
tortoise_paths=(
  CMakeLists.txt
  sql/base/tw_world_migrations.sql
  sql/create_databases.sql
  src/mangosd/mangosd.conf.dist.in
  src/realmd/realmd.conf.dist.in
)

if [[ -n "${TORTOISE_STABLE_REPOSITORY:-}${TORTOISE_STABLE_LATEST_COMMIT_HASH:-}${TORTOISE_STABLE_KNOWN_COMMIT_HASH:-}" ]]; then
  require_env TORTOISE_STABLE_REPOSITORY
  require_env TORTOISE_STABLE_LATEST_COMMIT_HASH
  require_env TORTOISE_STABLE_KNOWN_COMMIT_HASH

  tortoise_stable_latest_commit_hash="$(trim "$TORTOISE_STABLE_LATEST_COMMIT_HASH")"

  for path in "${tortoise_paths[@]}"; do
    add_github_check "$TORTOISE_STABLE_REPOSITORY" \
      "$TORTOISE_STABLE_KNOWN_COMMIT_HASH" "$tortoise_stable_latest_commit_hash" "$path" main
  done
fi

if [[ -n "${TORTOISE_UNSTABLE_REPOSITORY:-}${TORTOISE_UNSTABLE_LATEST_COMMIT_HASH:-}${TORTOISE_UNSTABLE_KNOWN_COMMIT_HASH:-}" ]]; then
  require_env TORTOISE_UNSTABLE_REPOSITORY
  require_env TORTOISE_UNSTABLE_LATEST_COMMIT_HASH
  require_env TORTOISE_UNSTABLE_KNOWN_COMMIT_HASH

  tortoise_unstable_latest_commit_hash="$(trim "$TORTOISE_UNSTABLE_LATEST_COMMIT_HASH")"

  for path in "${tortoise_paths[@]}"; do
    add_github_check "$TORTOISE_UNSTABLE_REPOSITORY" \
      "$TORTOISE_UNSTABLE_KNOWN_COMMIT_HASH" "$tortoise_unstable_latest_commit_hash" "$path" 1181dev
  done
fi

# Each module bundled into the `-modules` image variants has its configuration
# template watched, because we vendor it as
# `config/modules/<module>.conf.example`; a new key, a rename or a removal has
# to reach that copy or variant users are handed a stale template. The module
# code itself floats, exactly as the core's does. A rename or a removal needs
# no special handling here; `fetch_reference` already fails the run when a
# watched path stops resolving.
if [[ -n "${TW_MOD_AUTOSCALE_REPOSITORY:-}${TW_MOD_AUTOSCALE_LATEST_COMMIT_HASH:-}${TW_MOD_AUTOSCALE_KNOWN_COMMIT_HASH:-}" ]]; then
  require_env TW_MOD_AUTOSCALE_REPOSITORY
  require_env TW_MOD_AUTOSCALE_LATEST_COMMIT_HASH
  require_env TW_MOD_AUTOSCALE_KNOWN_COMMIT_HASH

  tw_mod_autoscale_latest_commit_hash="$(trim "$TW_MOD_AUTOSCALE_LATEST_COMMIT_HASH")"

  add_github_check "$TW_MOD_AUTOSCALE_REPOSITORY" \
    "$TW_MOD_AUTOSCALE_KNOWN_COMMIT_HASH" "$tw_mod_autoscale_latest_commit_hash" \
    conf/tw-mod-autoscale.conf.dist
fi

if [[ -n "${TW_MOD_LEECH_REPOSITORY:-}${TW_MOD_LEECH_LATEST_COMMIT_HASH:-}${TW_MOD_LEECH_KNOWN_COMMIT_HASH:-}" ]]; then
  require_env TW_MOD_LEECH_REPOSITORY
  require_env TW_MOD_LEECH_LATEST_COMMIT_HASH
  require_env TW_MOD_LEECH_KNOWN_COMMIT_HASH

  tw_mod_leech_latest_commit_hash="$(trim "$TW_MOD_LEECH_LATEST_COMMIT_HASH")"

  add_github_check "$TW_MOD_LEECH_REPOSITORY" \
    "$TW_MOD_LEECH_KNOWN_COMMIT_HASH" "$tw_mod_leech_latest_commit_hash" \
    conf/tw-mod-leech.conf.dist
fi

if [[ -n "${MARIADB_DOCKER_REPOSITORY:-}${MARIADB_DOCKER_LATEST_COMMIT_HASH:-}${MARIADB_DOCKER_KNOWN_COMMIT_HASH:-}" ]]; then
  require_env MARIADB_DOCKER_REPOSITORY
  require_env MARIADB_DOCKER_LATEST_COMMIT_HASH
  require_env MARIADB_DOCKER_KNOWN_COMMIT_HASH

  mariadb_docker_latest_commit_hash="$(trim "$MARIADB_DOCKER_LATEST_COMMIT_HASH")"

  # Patched MariaDB entrypoint. Our `docker/database/docker-entrypoint.sh`
  # extends functions defined in upstream's version, so any change there has to
  # be reviewed for compatibility.
  add_github_check "$MARIADB_DOCKER_REPOSITORY" \
    "$MARIADB_DOCKER_KNOWN_COMMIT_HASH" "$mariadb_docker_latest_commit_hash" \
    12.3/docker-entrypoint.sh
fi

if ((${#checks[@]} == 0)); then
  fail "No drift checks requested; provide environment variables for at least one source."
fi

failures=0

for check in "${checks[@]}"; do
  IFS='|' read -r desc known_url latest_url <<<"$check"

  fetch_reference "$known_url" "$workdir/known" "$desc"
  fetch_reference "$latest_url" "$workdir/latest" "$desc"

  if ! diff -u "$workdir/known" "$workdir/latest" >/dev/null; then
    printf '\n=== DRIFT DETECTED: %s ===\n' "$desc"
    diff -u "$workdir/known" "$workdir/latest" || true
    failures=$((failures + 1))
  else
    printf 'OK: %s\n' "$desc"
  fi
done

if ((failures > 0)); then
  printf '\n%s upstream reference(s) drifted from the pinned revision.\n' "$failures" >&2
  fail "Review the diff(s) above, refresh any local files that need to align, and bump the matching *_KNOWN_COMMIT_HASH."
fi
