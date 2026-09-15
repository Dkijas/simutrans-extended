#!/bin/bash
#
# This file is part of the Simutrans-Extended project under the Artistic License.
# (see LICENSE.txt)
#
# Check that a downloaded artifact is the one this job expects, by comparing
# the provenance record it carries against values the job already knows.
#
# Usage:
#   verify-provenance.sh <provenance.json> [--attempt N] key=value [key=value ...]
#
# Every key=value must match exactly or nothing proceeds.  With --attempt, the
# record's own run_attempt is checked for being a plausible attempt of a run
# that has reached attempt N - see below for why it is not required to equal N.
#
# TWO RUN IDENTITIES, NEVER THE SAME ONE
# --------------------------------------
# Simutrans-Extended has two different runs in play and they must not be
# confused:
#
#   ci_run_id       the CI run whose success made a commit eligible to be
#                   published at all.  It is the authority for WHICH COMMIT,
#                   and it belongs to a different workflow and a different
#                   run.
#   github.run_id   this run.  It is the source of the BYTES being signed.
#
# The caller passes each of them under its own key, and this script compares
# each against the value the caller supplies for that same key.  It never
# compares one against the other, and a caller that passed ci_run_id where
# run_id was meant would be told the values differ rather than quietly
# accepting an artifact from somewhere else.
#
# WHY run_attempt IS BOUNDED AND NOT PINNED
# -----------------------------------------
# Re-running only the failed jobs of a run deliberately reuses the artifacts
# the successful jobs already produced, so an artifact from an earlier attempt
# of THIS run is exactly what recovery looks like.  Demanding equality forbids
# the only repair GitHub offers; Simutrans Standard learned that on 2026-09-09
# and fixed it in r12269.  What the attempt must not be is nonsense, or from
# an attempt this run has not reached.

set -euo pipefail

FILE=${1:?usage: verify-provenance.sh <provenance.json> [--attempt N] key=value ...}
shift

CURRENT_ATTEMPT=""
if [ "${1:-}" = "--attempt" ]; then
	CURRENT_ATTEMPT=${2:?--attempt needs a number}
	shift 2
fi

if [ ! -f "$FILE" ]; then
	echo "::error::the artifact carries no provenance record at $FILE; refusing to use it."
	exit 1
fi

# plutil on a macOS runner, jq anywhere else.  Both read the same JSON; having
# the fallback is what lets these checks be exercised off a Mac.
if command -v plutil >/dev/null 2>&1; then
	get() { /usr/bin/plutil -extract "$1" raw -o - "$FILE" 2>/dev/null; }
elif command -v jq >/dev/null 2>&1; then
	get() { jq -r --arg k "$1" 'if has($k) then .[$k] else empty end' "$FILE"; }
else
	echo "::error::neither plutil nor jq is available; cannot read $FILE"
	exit 1
fi

echo "== provenance =============================================="
cat "$FILE"
echo

failures=0
for pair in "$@"; do
	case "$pair" in
		*=*) ;;
		*)
			echo "::error::expected key=value, got '$pair'"
			exit 1
			;;
	esac
	key=${pair%%=*}
	want=${pair#*=}
	got=$(get "$key" || true)
	if [ -z "$got" ]; then
		echo "::error::provenance has no '$key'; refusing to use this artifact."
		failures=$((failures + 1))
		continue
	fi
	if [ "$got" != "$want" ]; then
		echo "::error::provenance mismatch on '$key': artifact says '$got', this run expects '$want'."
		echo "::error::This artifact was not produced for this job; refusing to use it."
		failures=$((failures + 1))
		continue
	fi
	printf '  %-22s %s\n' "$key" "$got"
done

if [ -n "$CURRENT_ATTEMPT" ]; then
	attempt=$(get run_attempt || true)
	if ! grep -qE '^[0-9]{1,9}$' <<<"$attempt"; then
		echo "::error::provenance has no usable run_attempt ('$attempt')."
		failures=$((failures + 1))
	elif [ "$attempt" -lt 1 ] || [ "$attempt" -gt "$CURRENT_ATTEMPT" ]; then
		echo "::error::provenance says run_attempt '$attempt', but this run has only"
		echo "::error::reached attempt $CURRENT_ATTEMPT; refusing to use this artifact."
		failures=$((failures + 1))
	else
		printf '  %-22s %s\n' run_attempt "$attempt"
		if [ "$attempt" -ne "$CURRENT_ATTEMPT" ]; then
			echo "::notice::this artifact was made in attempt $attempt and is being used in attempt $CURRENT_ATTEMPT; that is what re-running failed jobs does."
		fi
	fi
fi

if [ "$failures" -gt 0 ]; then
	echo "::error::provenance check failed with $failures problem(s)."
	exit 1
fi

echo
echo "provenance accepted"
