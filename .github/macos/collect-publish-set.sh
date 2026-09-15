#!/bin/bash
#
# This file is part of the Simutrans-Extended project under the Artistic License.
# (see LICENSE.txt)
#
# Decide whether the signed archives are fit to be published, and lay them out
# under the public asset names.
#
# Usage:
#   collect-publish-set.sh <incoming-dir> <revision-id> <matrix-json> <out-dir>
#
# Writes into <out-dir>:
#   <asset>            each archive, renamed to the name users download
#   publish-list.txt   one asset name per line, for `gh release upload`
#   manifest-rows.txt  asset<TAB>arch<TAB>backend<TAB>min_macos<TAB>sha256
#
# Exits non-zero, having written nothing that would be uploaded, if any
# variant is missing or does not match what its name says.
#
# WHY THIS IS A SCRIPT
# --------------------
# It is the step where a mistake is invisible.  Everything before it fails
# loudly on a Mac; this one runs on Linux, moves files around and renames
# them, and the way it goes wrong is by shipping an archive that is not what
# its name claims - an arm64 build under an Intel name, an SDL2 build under
# the SDL3 name, an archive from a variant that never finished.  None of that
# shows up in a log that says "uploaded 4 files".
#
# Being a script rather than forty lines inside a YAML `run:` is what makes it
# possible to feed it a deliberately wrong set and watch it refuse.
#
# ALL OR NOTHING
# --------------
# If any variant is missing, nothing is published at all.  Publishing the two
# that did build would leave the other two names pointing at the previous
# night's archives while macos-signed.txt described this night's - four files
# that no longer agree with each other.  The previous archives staying in
# place, all four together, is the coherent outcome.

set -euo pipefail

INCOMING=${1:?usage: collect-publish-set.sh <incoming-dir> <revision-id> <matrix-json> <out-dir>}
REVISION_ID=${2:?revision id is required}
MATRIX=${3:?matrix json is required}
OUT=${4:?output directory is required}

mkdir -p "$OUT"
: > "$OUT/publish-list.txt"
: > "$OUT/manifest-rows.txt"

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT

failures=0
note_failure() {
	echo "::error::$1"
	failures=$((failures + 1))
}

echo "== collecting the publish set =============================="
echo "incoming : $INCOMING"
echo "revision : $REVISION_ID"
echo

while IFS=$'\t' read -r arch backend asset; do
	[ -n "$arch" ] || continue
	# Strip a trailing carriage return.  On the runner jq writes LF and this
	# does nothing; a jq built for Windows writes CRLF, and the CR would end
	# up INSIDE the asset name - producing a release asset called
	# "macos.zip<CR>" that every existing download link would miss, while
	# every log and directory listing still printed "macos.zip".  One
	# substitution removes a whole class of invisible failure, and this is the
	# step whose mistakes are invisible by nature.
	asset=${asset%$'\r'}
	zip="$INCOMING/simutrans-extended-macos-${arch}-${backend}-${REVISION_ID}-signed.zip"
	label="$arch/$backend -> $asset"

	if [ ! -f "$zip" ]; then
		note_failure "$label: no signed archive ($(basename "$zip"))"
		continue
	fi
	if [ ! -f "$zip.meta" ]; then
		note_failure "$label: no facts beside $(basename "$zip")"
		continue
	fi

	rm -rf "${probe:?}/x" && mkdir -p "$probe/x"
	if ! unzip -q "$zip" -d "$probe/x"; then
		note_failure "$label: the archive cannot be opened"
		continue
	fi

	app=$(find "$probe/x" -name '*.app' -maxdepth 3 -type d -print -quit)
	if [ -z "$app" ]; then
		note_failure "$label: no .app inside the archive"
		continue
	fi

	exe="$app/Contents/MacOS/simutrans-extended"
	if [ ! -f "$exe" ]; then
		note_failure "$label: no game executable inside the bundle"
		continue
	fi

	# The name says which architecture it is.  Check the bytes agree, so a
	# mix-up in the matrix cannot ship an Apple Silicon build to Intel users.
	# `file` names the architecture of a Mach-O without needing a Mac.
	got=$(file -b "$exe")
	case "$arch:$got" in
		arm64:*arm64*)   ;;
		x86_64:*x86_64*) ;;
		*)
			note_failure "$label: named $arch but the executable is: $got"
			continue
			;;
	esac

	# The backend has to agree too.  macos.zip and macos-sdl2.zip differ only
	# in this, both are arm64, and nothing else in either archive would show a
	# swap: the executables have the same name and very nearly the same size.
	plist="$app/Contents/Info.plist"
	got_backend=$(awk '/<key>SimutransBackend<\/key>/{getline; print}' "$plist" \
		| sed -n 's|.*<string>\(.*\)</string>.*|\1|p' | head -1)
	if [ "$got_backend" != "$backend" ]; then
		note_failure "$label: named $backend but the bundle says '${got_backend:-<nothing>}'"
		continue
	fi

	# The measured floor, carried from the job that could measure it.
	# Refusing without it is deliberate: a published archive that does not say
	# which macOS it needs is worse than no archive.
	min=$(sed -n 's/^min_macos=//p' "$zip.meta" | head -1)
	if ! grep -qE '^[0-9]+\.[0-9]+$' <<<"$min"; then
		note_failure "$label: .meta has no usable min_macos ('$min')"
		continue
	fi

	sha=$(sha256sum "$zip" | cut -d' ' -f1)
	cp "$zip" "$OUT/$asset"
	printf '%s\n' "$asset" >> "$OUT/publish-list.txt"
	printf '%s\t%s\t%s\t%s\t%s\n' "$asset" "$arch" "$backend" "$min" "$sha" \
		>> "$OUT/manifest-rows.txt"
	echo "  ok  $label  ($got, macOS $min or later)"
done < <(jq -r '.[] | [.arch, .backend, .asset] | @tsv' <<<"$MATRIX")

wanted=$(jq 'length' <<<"$MATRIX")
got=$(grep -c . < "$OUT/publish-list.txt" || true)

echo
if [ "$failures" -gt 0 ] || [ "$got" -ne "$wanted" ]; then
	echo "::error::$got of $wanted macOS variants are fit to publish."
	echo "::error::Refusing to publish part of a nightly: the variants that did"
	echo "::error::build are signed and remain as artifacts of this run, and the"
	echo "::error::previous macOS downloads are left exactly as they are."
	rm -f "$OUT/publish-list.txt" "$OUT/manifest-rows.txt"
	exit 1
fi

echo "all $wanted variants present and consistent with their names"
cat "$OUT/manifest-rows.txt"
