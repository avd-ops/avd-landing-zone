#!/bin/bash
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
# Offline what-if: the resources each parameter file would deploy, compared with a base commit.
# Uses `bicep snapshot` (no Azure sign-in, no calls): it evaluates the template with placeholder
# subscription and tenant IDs and lists the predicted resources. The base commit's snapshot is
# written beside this tree's parameter file and `--mode validate` prints the difference, in
# what-if's format. Advisory: it never fails on a difference, only when this tree's parameter
# file can't be evaluated. Expressions that need a live subscription (reference(), list*())
# stay unevaluated, so a real what-if still has the last word.
#
#   build/snapshot-diff.sh <base-ref> [summary-file]
#
# The identity variables must be set (placeholders are fine), as for build-params.
set -uo pipefail

base="${1:?usage: build/snapshot-diff.sh <base-ref> [summary-file]}"
summary="${2:-/dev/stdout}"
bicep="${BICEP:-bicep}"
repo="$(git rev-parse --show-toplevel)"
zero=00000000-0000-0000-0000-000000000000
args=(--subscription-id "$zero" --tenant-id "$zero" --location northcentralus --deployment-name avdlz)

work="$(mktemp -d)"
mkdir -p "$work/kept"
# A snapshot an operator already has beside a parameter file is set aside and put back on exit.
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
cleanup() {
  for k in "$work"/kept/*.snapshot.json; do [ -e "$k" ] && mv -f "$k" "$repo/parameters/"; done
  git -C "$repo" worktree remove --force "$work/base" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
if ! git -C "$repo" worktree add --detach "$work/base" "$base" >/dev/null 2>&1; then
  echo "Can't check out base '$base'; no comparison." >&2
  exit 0
fi

strip() { sed -E 's/\x1b\[[0-9;]*m//g'; }
fence=$'\x60\x60\x60'
block() { printf '%s\n%s\n%s\n' "$fence" "$1" "$fence" >> "$summary"; }
failed=0
{
  echo "## Offline what-if (bicep snapshot) against $(git -C "$repo" rev-parse --short "$base" 2>/dev/null || echo "$base")"
  echo
  echo "Predicted resources per parameter file, with placeholder IDs. Advisory: a live what-if (docs/ci.md) still has the last word."
  echo
} >> "$summary"

for f in "$repo"/parameters/*.bicepparam; do
  name="parameters/$(basename "$f")"
  snap="${f%.bicepparam}.snapshot.json"
  if [ -e "$snap" ]; then mv "$snap" "$work/kept/"; fi
  if [ ! -f "$work/base/$name" ]; then
    if out=$("$bicep" snapshot "$f" "${args[@]}" 2>&1); then
      echo "### $name: new parameter file" >> "$summary"
    else
      echo "### $name: can't be evaluated" >> "$summary"; block "$(echo "$out" | strip)"; failed=1
    fi
    rm -f "$snap"; continue
  fi
  if ! base_out=$("$bicep" snapshot "$work/base/$name" "${args[@]}" 2>&1); then
    echo "### $name: base can't be evaluated, no comparison" >> "$summary"
    block "$(echo "$base_out" | strip)"
    continue
  fi
  mv "$work/base/${name%.bicepparam}.snapshot.json" "$snap"
  out=$("$bicep" snapshot "$f" --mode validate "${args[@]}" 2>&1)
  rc=$?
  rm -f "$snap"
  if [ "$rc" -eq 0 ]; then
    echo "### $name: no change" >> "$summary"
  elif [[ $out == *'Snapshot validation failed'* ]]; then
    echo "### $name: changes" >> "$summary"
    block "$(echo "$out" | strip | sed -n '/Snapshot validation failed/,$p' | sed '1,2d')"
  else
    echo "### $name: can't be evaluated" >> "$summary"
    block "$(echo "$out" | strip)"
    failed=1
  fi
done
exit "$failed"
