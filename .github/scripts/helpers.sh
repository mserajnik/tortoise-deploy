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

# Resolves the Tortoise-WoW commit a unit's moving tag was last built from, by
# reading the commit hash tag that shares the package version of that moving
# tag. The units share one package, so the commit cannot be taken from "the
# newest hash tag"; it must come from the same version the moving tag points
# at. Prints an empty string when the unit has no prior build.
last_built_commit_for_unit() {
  local package_owner="$1"
  local package_name="$2"
  local moving_tag="$3"
  local commit_tag_regex="^$moving_tag-[0-9a-f]{40}$"
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

# Resolves the module revision a unit's moving tag was last built from, by
# reading the label the build wrote onto that image.
#
# The build writes a label into a per-architecture image configuration, and the
# index contains none, so this walks the index, then the child manifest, then
# the configuration blob. It prints an empty string when the image or the label
# is absent, and the caller turns that into the cutoff anchor.
last_built_module_commit_for_unit() {
  local registry_host="$1"
  local package_owner="$2"
  local package_name="$3"
  local moving_tag="$4"
  local module_directory="$5"
  local repository="$package_owner/$package_name"
  local accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json'
  local token
  local index
  local manifest
  local child_digest
  local config_digest
  local revision
  local body
  local status
  local config

  token="$(curl --fail --silent --show-error \
    "https://$registry_host/token?scope=repository:$repository:pull&service=$registry_host" |
    jq -r '.token // empty')" || true
  if [[ -z "$token" ]]; then
    fail "Could not obtain a pull token for '$repository' from $registry_host."
  fi

  # Only a 404 means there is no prior image. Collapsing 401, 403, 5xx, and a
  # transport error into the same answer would reset the scan floor to the
  # cutoff anchor and report that as fact.
  body="$(mktemp)" || fail "Failed to create a temporary file."
  status="$(curl --silent --show-error --location --output "$body" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer $token" --header "Accept: $accept" \
    "https://$registry_host/v2/$repository/manifests/$moving_tag")" || {
    rm -f "$body"
    fail "Could not reach $registry_host for '$repository:$moving_tag'."
  }
  case "$status" in
    200) index="$(cat "$body")" ;;
    404)
      rm -f "$body"
      printf '%s' ""
      return 0
      ;;
    *)
      rm -f "$body"
      fail "$registry_host answered HTTP $status for '$repository:$moving_tag'."
      ;;
  esac
  rm -f "$body"

  # A single-architecture image returns a manifest, and its own configuration
  # is then the one to read.
  child_digest="$(jq -r \
    'first(.manifests[]? | select(.platform.architecture != "unknown")) | .digest // empty' \
    <<<"$index")" ||
    fail "Index for '$repository:$moving_tag' is not readable."
  manifest="$index"
  if [[ -n "$child_digest" ]]; then
    if ! manifest="$(curl --fail --silent --show-error --location \
      --header "Authorization: Bearer $token" --header "Accept: $accept" \
      "https://$registry_host/v2/$repository/manifests/$child_digest")"; then
      fail "Could not read the child manifest $child_digest of '$repository:$moving_tag'."
    fi
  fi

  if [[ -z "${manifest//[[:space:]]/}" ]]; then
    fail "Manifest for '$repository:$moving_tag' is empty."
  fi

  config_digest="$(jq -r 'if type == "object" then .config.digest // empty
     else error("not a manifest") end' <<<"$manifest")" ||
    fail "Manifest for '$repository:$moving_tag' is not readable as a manifest."
  if [[ -z "$config_digest" ]]; then
    fail "Manifest for '$repository:$moving_tag' names no image config."
  fi

  if ! config="$(curl --fail --silent --show-error --location \
    --header "Authorization: Bearer $token" \
    "https://$registry_host/v2/$repository/blobs/$config_digest")"; then
    fail "Could not read the image config $config_digest of '$repository:$moving_tag'."
  fi

  # An empty body does not contain a JSON value, so `jq` skips the filter and
  # exits 0. The guard below stops the floor falling back to the anchor in
  # silence.
  if [[ -z "${config//[[:space:]]/}" ]]; then
    fail "Image config $config_digest of '$repository:$moving_tag' is empty."
  fi

  # An image built before the module joined the variant does not have this
  # label. An empty return then points the caller at the cutoff anchor, which
  # matches the answer for a missing image and is the right one, because
  # nothing published so far went through a scan for this module.
  revision="$(jq -r \
    --arg label "io.github.mserajnik.tortoise-deploy.modules.$module_directory.revision" \
    'if type == "object" then .config.Labels[$label] // empty
     else error("not an image config") end' <<<"$config")" ||
    fail "Image config $config_digest of '$repository:$moving_tag' is not readable as an image config."

  if [[ -n "$revision" && ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    fail "Label for module '$module_directory' on '$repository:$moving_tag' is not a 40-character commit hash: '$revision'."
  fi

  printf '%s' "$revision"
}
