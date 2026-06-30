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

# We watch `sql/create_databases.sql` because `import_world_schema` (in
# `db-functions.sh`) isolates its `tw_world` section with format-sensitive awk
# anchors (the dump preamble and the `CREATE DATABASE` / `USE` lines); a
# regenerated dump in a different format (e.g. an upstream database rebase)
# would silently mis-extract.
#
# In addition, we watch configs we mirror as `*.conf.example` and the top-level
# `CMakeLists.txt`, which is where new `find_package(...)` would typically
# introduce a new dependency that we would need to install.
#
# Files we only patch (such as `AutoUpdater.cpp`) are not watched here: a drift
# that breaks a patch already fails the build via
# `TORTOISE_FAIL_ON_PATCH_ERROR`.
#
# Tortoise-WoW is built from two branches (`main` and `1181dev`) that can
# diverge, so each is checked against its own pinned commit.
tortoise_paths=(
  CMakeLists.txt
  sql/create_databases.sql
  src/mangosd/mangosd.conf.dist.in
  src/realmd/realmd.conf.dist.in
)

if [[ -n "${TORTOISE_STABLE_REPOSITORY:-}${TORTOISE_STABLE_LATEST_COMMIT_HASH:-}${TORTOISE_STABLE_KNOWN_COMMIT_HASH:-}" ]]; then
  require_env TORTOISE_STABLE_REPOSITORY
  require_env TORTOISE_STABLE_LATEST_COMMIT_HASH
  require_env TORTOISE_STABLE_KNOWN_COMMIT_HASH

  # shellcheck disable=SC2153
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

  # shellcheck disable=SC2153
  tortoise_unstable_latest_commit_hash="$(trim "$TORTOISE_UNSTABLE_LATEST_COMMIT_HASH")"

  for path in "${tortoise_paths[@]}"; do
    add_github_check "$TORTOISE_UNSTABLE_REPOSITORY" \
      "$TORTOISE_UNSTABLE_KNOWN_COMMIT_HASH" "$tortoise_unstable_latest_commit_hash" "$path" 1181dev
  done
fi

if [[ -n "${MARIADB_DOCKER_REPOSITORY:-}${MARIADB_DOCKER_LATEST_COMMIT_HASH:-}${MARIADB_DOCKER_KNOWN_COMMIT_HASH:-}" ]]; then
  require_env MARIADB_DOCKER_REPOSITORY
  require_env MARIADB_DOCKER_LATEST_COMMIT_HASH
  require_env MARIADB_DOCKER_KNOWN_COMMIT_HASH

  # shellcheck disable=SC2153
  mariadb_docker_latest_commit_hash="$(trim "$MARIADB_DOCKER_LATEST_COMMIT_HASH")"

  # Patched MariaDB entrypoint. Our `docker/database/docker-entrypoint.sh`
  # extends functions defined in upstream's version, so any change there has to
  # be reviewed for compatibility.
  add_github_check "$MARIADB_DOCKER_REPOSITORY" \
    "$MARIADB_DOCKER_KNOWN_COMMIT_HASH" "$mariadb_docker_latest_commit_hash" \
    11.8/docker-entrypoint.sh
fi

if ((${#checks[@]} == 0)); then
  fail "No drift checks requested; provide environment variables for at least one source."
fi

failures=0

for check in "${checks[@]}"; do
  IFS='|' read -r desc known_url latest_url <<<"$check"

  curl --fail --silent --show-error --location \
    --output "$workdir/known" "$known_url"
  curl --fail --silent --show-error --location \
    --output "$workdir/latest" "$latest_url"

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
