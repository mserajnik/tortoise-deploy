#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Flattens a stream's entry in `.github/migration-edit-state.json` to the
# `TORTOISE_MIGRATION_EDITS` build argument: pipe-separated
# `<database>:<commit-hash>` entries for each of `world` and `character` (empty
# value where the stream has no recorded edit for that target). The streams are
# built separately, so a stream key is required alongside the state file.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

if [[ "$#" -ne 2 ]]; then
  fail "Usage: $0 <state-file> <stream-key>"
fi

state_file="$1"
stream_key="$2"

# A state file `jq` cannot read as an object would yield an empty token, which
# reads as "this stream has no recorded edit".
if ! jq -e '
  type == "object"
  and all(.. | objects | select(has("commit")) | .commit;
          type == "string" and length == 40 and test("^[0-9a-f]{40}$"))
' "$state_file" >/dev/null; then
  fail "State file '$state_file' is missing, is not a JSON object, or holds a malformed commit hash."
fi

# An unrecognized stream indexes to `null`, which renders the same empty token
# for every target and is indistinguishable from "no recorded edit".
if ! jq -e --arg stream "$stream_key" 'has($stream)' "$state_file" >/dev/null; then
  fail "State file '$state_file' has no entry for stream '$stream_key'."
fi

jq -r --arg stream "$stream_key" '
  ["world", "character"] as $order
  | .[$stream] as $targets
  | [$order[] as $db | "\($db):\($targets[$db].commit // "")"]
  | join("|")
' "$state_file"
