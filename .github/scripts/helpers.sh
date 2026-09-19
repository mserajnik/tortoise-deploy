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

# Reads one label off the image a unit's moving tag points at.
#
# The build writes a label into a per-architecture image configuration, which
# an index does not carry, so this walks the index, then the child manifest,
# then the configuration blob. It prints an empty string when the image or the
# label is absent.
image_label_for_unit() {
  require_env GH_TOKEN

  local registry_host="$1"
  local package_owner="$2"
  local package_name="$3"
  local moving_tag="$4"
  local label="$5"
  local repository="$package_owner/$package_name"
  local accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json'
  local token
  local index
  local manifest
  local child_digest
  local config_digest
  local value
  local body
  local status
  local config

  # The request sends credentials so that a package that does not exist reaches
  # the 404 branch at the manifest hop below, where an absent image becomes an
  # empty result. GHCR refuses an anonymous request for such a package with
  # 403, and the walk aborts.
  token="$(curl --fail --silent --show-error --user "x:$GH_TOKEN" \
    "https://$registry_host/token?scope=repository:$repository:pull&service=$registry_host" |
    jq -r '.token // empty')" || true
  if [[ -z "$token" ]]; then
    fail "Could not obtain a pull token for '$repository' from $registry_host. Check the credential and its package access."
  fi

  # Only a 404 means there is no prior image.
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
  # exits 0. The guard below stops an empty answer passing for a recorded one.
  if [[ -z "${config//[[:space:]]/}" ]]; then
    fail "Image config $config_digest of '$repository:$moving_tag' is empty."
  fi

  # An image without this label returns empty, which means the same as a
  # missing image: there is nothing to compare against.
  value="$(jq -r --arg label "$label" \
    'if type == "object" then .config.Labels[$label] // empty
     else error("not an image config") end' <<<"$config")" ||
    fail "Image config $config_digest of '$repository:$moving_tag' is not readable as an image config."

  if [[ -n "$value" && ! "$value" =~ ^[0-9a-f]{40}$ ]]; then
    fail "Label '$label' on '$repository:$moving_tag' is not a 40-character commit hash: '$value'."
  fi

  printf '%s' "$value"
}

# Resolves the Tortoise-WoW commit a unit's moving tag was last built from, by
# reading the label the build wrote onto that image. Prints an empty string
# when the image does not record a commit.
last_built_commit_for_unit() {
  local registry_host="$1"
  local package_owner="$2"
  local package_name="$3"
  local moving_tag="$4"

  image_label_for_unit "$registry_host" "$package_owner" "$package_name" \
    "$moving_tag" org.opencontainers.image.revision
}

# The revision of one bundled module, read off the variant's own image.
last_built_module_commit_for_unit() {
  local registry_host="$1"
  local package_owner="$2"
  local package_name="$3"
  local moving_tag="$4"
  local module_directory="$5"

  image_label_for_unit "$registry_host" "$package_owner" "$package_name" \
    "$moving_tag" \
    "io.github.mserajnik.tortoise-deploy.modules.$module_directory.revision"
}
