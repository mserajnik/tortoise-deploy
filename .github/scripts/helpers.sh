# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# shellcheck shell=bash

# Shared helpers sourced by the other scripts in this directory: error
# handling, environment variable checks, output writers for GitHub Actions,
# GHCR endpoint helpers, and commit hash resolution.

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_env() {
  local name="$1"

  if [[ -z "${!name:-}" ]]; then
    fail "Environment variable '$name' is required."
  fi
}

trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
}

write_output() {
  require_env GITHUB_OUTPUT

  local name="$1"
  local value="$2"

  printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
}

write_multiline_output() {
  require_env GITHUB_OUTPUT

  local name="$1"
  local value="$2"
  local delimiter
  delimiter="EOF_${name}_$(date +%s)_$RANDOM"

  {
    printf '%s<<%s\n' "$name" "$delimiter"
    printf '%s\n' "$value"
    printf '%s\n' "$delimiter"
  } >>"$GITHUB_OUTPUT"
}

package_versions_endpoint() {
  local owner="$1"
  local package_name="$2"
  local owner_endpoint

  # Resolve the owner endpoint before use, and return rather than printing on
  # failure: `fail` inside a substitution exits only its own subshell, so
  # printing anyway would build an endpoint missing its namespace, which 404s
  # exactly like a package that was never published. Callers must not use this
  # in argument position, where the non-zero status would be discarded.
  owner_endpoint="$(package_owner_endpoint "$owner")" || return 1

  printf '%s/packages/container/%s/versions' \
    "$owner_endpoint" \
    "$package_name"
}

package_version_endpoint() {
  local owner="$1"
  local package_name="$2"
  local package_version_id="$3"
  local owner_endpoint

  owner_endpoint="$(package_owner_endpoint "$owner")" || return 1

  printf '%s/packages/container/%s/versions/%s' \
    "$owner_endpoint" \
    "$package_name" \
    "$package_version_id"
}

package_owner_endpoint() {
  local owner="$1"
  local owner_type
  local namespace

  # Without the check a failed lookup leaves `owner_type` empty and reports an
  # unsupported type, which points at the wrong thing entirely.
  if ! owner_type="$(gh api "/users/$owner" --jq '.type')"; then
    fail "Failed to look up the package owner '$owner'."
  fi

  case "$owner_type" in
    Organization)
      namespace="orgs"
      ;;
    User)
      namespace="users"
      ;;
    *)
      fail "Unsupported package owner type '$owner_type' for '$owner'."
      ;;
  esac

  printf '/%s/%s' "$namespace" "$owner"
}

resolve_commit_hash() {
  local repository_owner="$1"
  local repository_name="$2"
  local repository_ref="$3"
  local result

  result="$(gh api \
    "/repos/$repository_owner/$repository_name/commits/$repository_ref" \
    --jq '.sha')"
  if [[ ! "$result" =~ ^[0-9a-f]{40}$ ]]; then
    fail "Could not resolve $repository_owner/$repository_name@$repository_ref to a 40-character commit hash."
  fi

  printf '%s' "$result"
}

# Resolves the Tortoise-WoW commit a stream's moving tag (`stable` or
# `unstable`) was last built from, by reading the commit hash tag that shares
# the package version of that moving tag. The streams share one package, so the
# commit cannot be taken from "the newest hash tag"; it must come from the same
# version the moving tag points at. Prints an empty string when the stream has
# no prior build.
last_built_commit_for_stream() {
  local package_owner="$1"
  local package_name="$2"
  local moving_tag="$3"
  # The bare form matches images published before commit hash tags carried the
  # stream name.
  # TODO: Drop the bare form once no such version is left.
  local commit_tag_regex="^($moving_tag-)?[0-9a-f]{40}$"
  local endpoint
  local commit_tag
  local errors
  local status

  endpoint="$(package_versions_endpoint "$package_owner" "$package_name")"

  # An empty endpoint means the owner lookup failed; report that rather than
  # querying the API root.
  if [[ -z "$endpoint" ]]; then
    fail "Failed to resolve the package versions endpoint for '$package_owner/$package_name'."
  fi

  # `gh`'s stderr is kept out of the value: an advisory on an otherwise
  # successful call would land inside the prefix strip below.
  errors="$(mktemp)" || fail "Failed to create a temporary file."

  set +e
  commit_tag="$(gh api --paginate "$endpoint?per_page=100" \
    --jq "[.[]
           | select((.metadata.container.tags // []) | index(\"$moving_tag\"))
           | .metadata.container.tags[]
           | select(test(\"$commit_tag_regex\"))]
          | first // empty" 2>"$errors")"
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    # `gh` writes the error body to stdout, so only stderr can be tested here.
    if grep -Fq "HTTP 404" "$errors"; then
      rm -f "$errors"
      printf '%s' ""
      return 0
    fi

    cat "$errors" >&2
    rm -f "$errors"
    fail "Failed to query package versions for '$package_owner/$package_name'."
  fi

  rm -f "$errors"

  printf '%s' "${commit_tag#"$moving_tag-"}"
}
