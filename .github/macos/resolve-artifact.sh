#!/bin/bash
#
# This file is part of the Simutrans-Extended project under the Artistic License.
# (see LICENSE.txt)
#
# Resolve an artifact NAME to exactly one artifact ID, using what GitHub itself
# records about where that artifact came from, before anything is downloaded.
#
# Usage: resolve-artifact.sh <repository> <run-id> <artifact-name>
#
# Environment:
#   GH_TOKEN        a token gh can use (required)
#   GITHUB_OUTPUT   if set, "id=<n>" is appended to it
#
# Prints the id on stdout's last line so a caller without GITHUB_OUTPUT can
# still use it.
#
# WHY BY ID AND NOT BY NAME
# -------------------------
# Asking by name works, but it would also accept whichever artifact happened
# to carry the name if there were ever more than one.  The id is what
# identifies an artifact; the name is a label.  Two candidates mean the run is
# not what the caller assumes, so this stops rather than choosing, and prints
# both rather than guessing.
#
# The run id and the repository id are read from GitHub's record of the
# producer, not from anything the artifact says about itself.  A manifest
# inside an artifact is the artifact's own account of where it came from; this
# is the platform's.
#
# This exists as a script, rather than as three copies of the same block of
# YAML, because it is the part that was wrong once before.  In Simutrans
# Standard the equivalent gate pinned `run_attempt` as well, which made
# "Re-run failed jobs" - the only repair GitHub offers - impossible: the
# surviving artifact honestly reported attempt 1 while the retry was attempt 2.
# A provenance gate must fix WHAT produced the work, not HOW it was scheduled.

set -euo pipefail

REPO=${1:?usage: resolve-artifact.sh <repository> <run-id> <artifact-name>}
RUN_ID=${2:?run id is required}
WANT=${3:?artifact name is required}

: "${GH_TOKEN:?GH_TOKEN is required}"

all=$(gh api --paginate \
	"repos/$REPO/actions/runs/$RUN_ID/artifacts" \
	--jq ".artifacts[] | select(.name == \"$WANT\" and .expired == false) | \"\(.id) \(.workflow_run.id) \(.workflow_run.repository_id) \(.created_at)\"")

count=$(grep -c . <<<"$all" || true)
if [ "$count" -eq 0 ]; then
	echo "::error::no live artifact named '$WANT' in run $RUN_ID of $REPO."
	echo "::error::It was never uploaded, or it has expired; there is nothing to use."
	exit 1
fi
if [ "$count" -gt 1 ]; then
	echo "::error::$count live artifacts are named '$WANT' in run $RUN_ID:"
	# SC2001: parameter expansion cannot prefix every line of a multi-line
	# value, which is exactly what is wanted here.
	# shellcheck disable=SC2001
	sed 's/^/::error::  /' <<<"$all"
	echo "::error::Refusing to guess which one is meant."
	exit 1
fi

id=$(awk '{ print $1 }' <<<"$all")
run=$(awk '{ print $2 }' <<<"$all")
repo_id=$(awk '{ print $3 }' <<<"$all")
created=$(awk '{ print $4 }' <<<"$all")

if [ "$run" != "$RUN_ID" ]; then
	echo "::error::artifact $id belongs to run $run, not $RUN_ID."
	exit 1
fi

want_repo=$(gh api "repos/$REPO" --jq .id)
if [ "$repo_id" != "$want_repo" ]; then
	echo "::error::artifact $id belongs to repository $repo_id, not $want_repo ($REPO)."
	exit 1
fi

echo "artifact    : $WANT"
echo "artifact id : $id"
echo "produced by : run $run in repository $repo_id"
echo "created     : $created"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "id=$id" >> "$GITHUB_OUTPUT"
fi
echo "$id"
