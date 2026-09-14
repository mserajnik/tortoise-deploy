#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Flattens a unit's entry in `.github/migration-edit-state.json` to the
# `TORTOISE_MIGRATION_EDITS` build argument: pipe-separated
# `<database>:<commit-hash>` entries for each of `world` and `character` (empty
# value where the unit has no recorded edit for that target). Units are built
# separately, so a unit is required alongside the state file.
#
# A target is recorded under the source its edit came from, which today is
# always `core`, and in the shape its remedy takes: a bare object where the
# database image can re-create the target, and a list where the operator has to
# fix it by hand. The argument keeps only the commit hash the container-side
# parser reads, so both shapes flatten to it. A list holds its newest edit at
# index 0.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

if [[ "$#" -ne 2 ]]; then
  fail "Usage: $0 <state-file> <unit>"
fi

state_file="$1"
unit="$2"

# A state file jq cannot read as an object would yield an empty token, which
# reads as "this unit has no recorded edit." `version` tells this shape apart
# from the flat one that preceded it, whose entries this filter would silently
# render as empty.
if ! jq -e '
  type == "object"
  and .version == 1
  and (.streams | type) == "object"
  and all(.streams[]; type == "object"
      and (keys_unsorted - ["world", "character"]) == []
      and all(.[]; type == "object"
          and all(.[];
                (type == "object" and has("commit"))
                or (type == "array" and length > 0
                    and all(.[]; type == "object" and has("commit"))))))
  and all(.. | objects | select(has("commit")) | .commit;
          type == "string" and length == 40 and test("^[0-9a-f]{40}$"))
' "$state_file" >/dev/null; then
  fail "State file '$state_file' is missing, is not a version 1 state object with 'world' and 'character' targets, or holds a malformed commit hash."
fi

# An unrecognized unit indexes to `null`, which renders the same empty token
# for every target and is indistinguishable from "no recorded edit."
if ! jq -e --arg unit "$unit" '.streams | has($unit)' "$state_file" >/dev/null; then
  fail "State file '$state_file' has no entry for unit '$unit'."
fi

jq -r --arg unit "$unit" '
  ["world", "character"] as $order
  | .streams[$unit] as $targets
  | [$order[] as $db
     | ($targets[$db].core // null) as $edit
     | (if ($edit | type) == "array" then $edit[0].commit else $edit.commit end) as $commit
     | "\($db):\($commit // "")"]
  | join("|")
' "$state_file"
