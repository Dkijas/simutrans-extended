#!/bin/bash
#
# This file is part of the Simutrans-Extended project under the Artistic License.
# (see LICENSE.txt)
#
# Assemble the macOS payload that gets signed: one application bundle holding
# every executable and every library, with the game data beside it.
#
# Usage:
#   make-bundle.sh --install-root DIR --tools-dir DIR --icon FILE \
#                  --backend sdl2|sdl3 --arch arm64|x86_64 \
#                  --commit SHA --revision SHORTSHA --out DIR
#
# WHY THE LAYOUT IS THE WAY IT IS
# -------------------------------
# Simutrans-Extended is not Simutrans Standard here, and copying Standard's
# layout would produce a bundle that cannot start.
#
# simmain.cc takes the directory of argv[0], and when that directory ends in
# ".app/Contents/MacOS/" it strips those twenty characters and everything back
# to the previous slash, then chdir()s there.  So for Extended the data
# directory is the directory that CONTAINS the application, not a folder
# inside it.  Standard installs its data at Contents/Resources/simutrans and
# would be wrong here.
#
# That single fact decides three things:
#
#   * config/, font/, text/, themes/, script/, music/ and the paksets sit
#     BESIDE the .app, not inside it.
#   * the server binary is nevertheless placed INSIDE the bundle, at
#     Contents/MacOS/.  It resolves its data through exactly the same rule, so
#     from in there it still finds the data beside the bundle - and being
#     inside means it is covered by the bundle's signature and its
#     notarization ticket instead of shipping as loose unsigned code.
#   * makeobj and nettool go in beside it for the same reason.  Neither needs
#     the data directory at all; what they need is to be signed, and the only
#     thing that is signed here is the bundle.
#
# Small wrapper scripts beside the .app keep the three command-line tools
# reachable under the names the previous package used.  They are scripts, not
# Mach-O, so they are not code as far as codesign and the notary service are
# concerned; they exec the real binary inside the bundle with its full path,
# which is what makes the data directory resolve correctly.
#
# Libraries go to Contents/Frameworks and are reached through
# @executable_path/../Frameworks.  Every one of them has to be inside the
# bundle: the Hardened Runtime's library validation only accepts libraries
# signed with the same Team ID, and a library outside the bundle would be
# neither signed nor stapled.

set -euo pipefail

INSTALL_ROOT=""
TOOLS_DIR=""
ICON=""
BACKEND=""
ARCH=""
COMMIT=""
REVISION=""
OUT=""

while [ $# -gt 0 ]; do
	case "$1" in
		--install-root) INSTALL_ROOT=$2; shift 2 ;;
		--tools-dir)    TOOLS_DIR=$2;    shift 2 ;;
		--icon)         ICON=$2;         shift 2 ;;
		--backend)      BACKEND=$2;      shift 2 ;;
		--arch)         ARCH=$2;         shift 2 ;;
		--commit)       COMMIT=$2;       shift 2 ;;
		--revision)     REVISION=$2;     shift 2 ;;
		--out)          OUT=$2;          shift 2 ;;
		*)
			echo "::error::unknown argument '$1'"
			exit 1
			;;
	esac
done

for pair in "install-root:$INSTALL_ROOT" "tools-dir:$TOOLS_DIR" "icon:$ICON" \
            "backend:$BACKEND" "arch:$ARCH" "commit:$COMMIT" \
            "revision:$REVISION" "out:$OUT"; do
	if [ -z "${pair#*:}" ]; then
		echo "::error::--${pair%%:*} is required"
		exit 1
	fi
done

case "$BACKEND" in
	sdl2|sdl3) ;;
	*) echo "::error::--backend must be sdl2 or sdl3, not '$BACKEND'"; exit 1 ;;
esac
case "$ARCH" in
	arm64|x86_64) ;;
	*) echo "::error::--arch must be arm64 or x86_64, not '$ARCH'"; exit 1 ;;
esac

APP_NAME="simutrans-extended.app"
GAME="simutrans-extended"
TOOLS=(simutrans-extended-server makeobj-extended nettool-extended)
# Reverse DNS for the project's own domain.  It is not derived from the
# signing Team ID and does not need to be: for Developer ID distribution
# outside the Mac App Store the bundle identifier is a name, not a claim.
BUNDLE_ID="com.simutrans.extended"

payload="$OUT/simutrans"
app="$payload/$APP_NAME"
macos_dir="$app/Contents/MacOS"
fw_dir="$app/Contents/Frameworks"
res_dir="$app/Contents/Resources"

echo "== assembling the macOS payload ============================"
echo "backend      : $BACKEND"
echo "architecture : $ARCH"
echo "revision     : $REVISION"
echo "commit       : $COMMIT"
echo "output       : $payload"
echo

# ---------------------------------------------------------------------------
# 1. The data tree, from `cmake --install`.
#
# The install prefix holds simutrans/<game binary> plus the whole data tree.
# The binary is moved into the bundle; everything else stays beside it, which
# is where the product expects to find it.
# ---------------------------------------------------------------------------
src="$INSTALL_ROOT/simutrans"
if [ ! -d "$src" ]; then
	echo "::error::install tree not found: $src"
	echo "::error::Expected the output of 'cmake --install <build> --prefix $INSTALL_ROOT'."
	exit 1
fi
if [ ! -f "$src/$GAME" ]; then
	echo "::error::no $GAME in the install tree at $src"
	exit 1
fi

rm -rf "$OUT"
mkdir -p "$payload"
# ditto rather than cp: it is the tool that preserves macOS metadata, and the
# same tool archives the result later.
/usr/bin/ditto "$src" "$payload"

mkdir -p "$macos_dir" "$fw_dir" "$res_dir"
mv "$payload/$GAME" "$macos_dir/$GAME"

for t in "${TOOLS[@]}"; do
	if [ ! -f "$TOOLS_DIR/$t" ]; then
		echo "::error::missing tool binary: $TOOLS_DIR/$t"
		exit 1
	fi
	/usr/bin/ditto "$TOOLS_DIR/$t" "$macos_dir/$t"
	chmod 0755 "$macos_dir/$t"
done
chmod 0755 "$macos_dir/$GAME"

if [ ! -f "$ICON" ]; then
	echo "::error::icon not found: $ICON"
	exit 1
fi
/usr/bin/ditto "$ICON" "$res_dir/$GAME.icns"

# ---------------------------------------------------------------------------
# 2. Info.plist.
#
# Written here rather than by OSX/plistgen.sh: that script dates from the
# Makefile build, shells out to a helper binary for the version, and emits
# org.simutrans-extended.simutrans-extended as the identifier.  The values
# that matter are the ones a signed and notarized bundle is judged on, and
# they are set explicitly.
#
# LSMinimumSystemVersion is deliberately NOT written.  The real floor is the
# highest LC_BUILD_VERSION across every Mach-O in the bundle, which is set by
# the Homebrew bottles rather than by this packaging, and inspect-bundle.sh
# measures it.  A number written here that disagreed with the binaries would
# be worse than no number at all.
# ---------------------------------------------------------------------------
year=$(date -u +%Y)
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Simutrans Extended</string>
	<key>CFBundleName</key>
	<string>Simutrans Extended</string>
	<key>CFBundleExecutable</key>
	<string>$GAME</string>
	<key>CFBundleIconFile</key>
	<string>$GAME.icns</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$REVISION</string>
	<key>CFBundleVersion</key>
	<string>$REVISION</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright 1997-$year by the Simutrans team</string>
	<key>SimutransBackend</key>
	<string>$BACKEND</string>
	<key>SimutransCommit</key>
	<string>$COMMIT</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$app/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# 3. Bundle the non-system libraries.
#
# The build links against Homebrew keg paths that exist only on the runner.
# Each dependency is copied into Contents/Frameworks and every reference to it
# is rewritten, recursively, until nothing outside /usr/lib and /System is
# named any more.
#
# Deliberately not dylibbundler: it prompts for @rpath dependencies it cannot
# resolve and hangs a CI run forever.
#
# Every variable in these functions is local.  bundle_lib recurses, and a
# global would be overwritten by the inner call - which mis-retargets a
# library in a way that only shows up at run time on a user's machine.
# ---------------------------------------------------------------------------
list_rpaths() {
	otool -l "$1" | awk '/cmd LC_RPATH/{f=1; next} f && / path /{print $2; f=0}'
}

resolve_dep() {
	local dep="$1"
	local base rp
	shift
	case "$dep" in
		@rpath/*)
			base="${dep#@rpath/}"
			for rp in "$@"; do
				if [ -f "$rp/$base" ]; then echo "$rp/$base"; return 0; fi
			done
			return 1
			;;
		*)
			[ -f "$dep" ] && { echo "$dep"; return 0; }
			return 1
			;;
	esac
}

bundle_lib() {
	local libfile="$1"
	local extra_rpaths="$2"
	local lrpaths ldeps ldep lreal lbase
	lrpaths=$(list_rpaths "$libfile")
	ldeps=$(otool -L "$libfile" | awk 'NR>1 {print $1}')
	while read -r ldep; do
		case "$ldep" in
			/usr/lib/*|/System/*|@loader_path/*|@executable_path/*|"") continue ;;
		esac
		# shellcheck disable=SC2086
		lreal=$(resolve_dep "$ldep" $lrpaths $extra_rpaths) || {
			echo "::error::cannot resolve dependency $ldep of $libfile"
			exit 1
		}
		lbase=$(basename "$lreal")
		if [ ! -f "$fw_dir/$lbase" ]; then
			cp -L "$lreal" "$fw_dir/$lbase"
			chmod 0644 "$fw_dir/$lbase"
			install_name_tool -id "@loader_path/$lbase" "$fw_dir/$lbase"
			bundle_lib "$fw_dir/$lbase" "$extra_rpaths"
		fi
		install_name_tool -change "$ldep" "@loader_path/$lbase" "$libfile"
	done <<< "$ldeps"
}

bundle_binary() {
	local bin="$1"
	local rpaths deps dep real base
	rpaths=$(list_rpaths "$bin")
	deps=$(otool -L "$bin" | awk 'NR>1 {print $1}')
	while read -r dep; do
		case "$dep" in
			/usr/lib/*|/System/*|@loader_path/*|@executable_path/*|"") continue ;;
		esac
		# shellcheck disable=SC2086
		real=$(resolve_dep "$dep" $rpaths) || {
			echo "::error::cannot resolve dependency $dep of $bin"
			exit 1
		}
		base=$(basename "$real")
		if [ ! -f "$fw_dir/$base" ]; then
			cp -L "$real" "$fw_dir/$base"
			chmod 0644 "$fw_dir/$base"
			install_name_tool -id "@loader_path/$base" "$fw_dir/$base"
			bundle_lib "$fw_dir/$base" "$rpaths"
		fi
		install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" "$bin"
	done <<< "$deps"
}

# Drop EVERY LC_RPATH from one Mach-O file.
#
# An LC_RPATH is consulted for one purpose only: resolving a dependency whose
# name begins with @rpath/.  By the time this runs, every such dependency has
# been rewritten to @loader_path or @executable_path, which is asserted below
# before a single entry is removed.  With no @rpath/ dependency left, every
# LC_RPATH is dead, and dead search paths are not harmless:
#
#   * an absolute one (/opt/homebrew/lib, /usr/local/lib) would let a library
#     of the right name on the user's machine be found in preference to the
#     signed copy inside the bundle;
#   * a relative one can escape the bundle just as effectively.  The first
#     rehearsal, on 2026-09-15, shipped libSDL2-2.0.0.dylib still carrying
#     @loader_path/../../../../opt/sdl3/lib - a Homebrew bottle's own relative
#     path, which from Contents/Frameworks/ resolves outside the application
#     entirely.  An earlier version of this function only removed entries that
#     did not start with '@', so that one survived.
#
# -delete_rpath removes one entry at a time and the same path can appear more
# than once, so each is removed until none is left.
strip_all_rpaths() {
	local f="$1"
	local rp
	while :; do
		rp=$(list_rpaths "$f" | head -1)
		[ -n "$rp" ] || break
		install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || {
			echo "::error::cannot remove LC_RPATH '$rp' from $f"
			exit 1
		}
	done
}

echo "-- bundling libraries"
for bin in "$GAME" "${TOOLS[@]}"; do
	echo "   $bin"
	bundle_binary "$macos_dir/$bin"
done
echo "   libraries in Contents/Frameworks: $(find "$fw_dir" -type f | wc -l | tr -d ' ')"

# Every LC_RPATH is about to be removed, so first prove none is still needed.
# An @rpath/ dependency surviving here would mean the rewriting above missed
# something, and removing the search paths would turn that into a library that
# cannot be found at all on a user's Mac.
echo "-- checking no @rpath dependency survived the rewriting"
left=0
while IFS= read -r -d '' f; do
	file -b "$f" | grep -q 'Mach-O' || continue
	deps=$(otool -L "$f" | awk 'NR>1 {print $1}')
	while read -r d; do
		case "$d" in
			@rpath/*)
				echo "::error::${f#"$app"/} still depends on $d"
				left=$((left + 1))
				;;
		esac
	done <<< "$deps"
done < <(find "$app" -type f -print0)
if [ "$left" -gt 0 ]; then
	echo "::error::$left @rpath dependency/dependencies were not rewritten."
	echo "::error::Refusing to remove the search paths that still resolve them."
	exit 1
fi
echo "   none: every dependency is @loader_path, @executable_path, /usr/lib or /System"

echo "-- removing every now-dead search path"
while IFS= read -r -d '' f; do
	if file -b "$f" | grep -q 'Mach-O'; then
		strip_all_rpaths "$f"
	fi
done < <(find "$app" -type f -print0)

# ---------------------------------------------------------------------------
# 4. Wrapper scripts for the command-line tools.
#
# `exec` with the bundle's full path is not a detail: the real binary works
# out its data directory from argv[0], so the path it is started with is what
# makes config/ and the paksets resolve.
# ---------------------------------------------------------------------------
for t in "${TOOLS[@]}"; do
	cat > "$payload/$t" <<WRAPPER
#!/bin/sh
#
# Runs $t from inside $APP_NAME.
#
# The binary lives in the bundle so that it is covered by the code signature
# and the notarization ticket.  It is started with its full path on purpose:
# Simutrans-Extended derives its data directory from argv[0], and from inside
# .app/Contents/MacOS/ that resolves to this directory - which is where
# config/, font/ and the paksets are.
here=\$(cd -- "\$(dirname -- "\$0")" && pwd)
exec "\$here/$APP_NAME/Contents/MacOS/$t" "\$@"
WRAPPER
	chmod 0755 "$payload/$t"
done

# ---------------------------------------------------------------------------
# 5. A note for whoever opens the download.
# ---------------------------------------------------------------------------
cat > "$payload/README-macOS.txt" <<README
Simutrans-Extended for macOS
============================

Revision      $REVISION
Commit        $COMMIT
Backend       $BACKEND
Architecture  $ARCH

Starting the game
-----------------
Double-click $APP_NAME.  Keep it in this folder: the game reads config/,
font/, text/, themes/ and the paksets from the folder that CONTAINS the
application, so moving the application on its own will stop it finding them.

Saved games and settings go to ~/Library/Simutrans, not into this folder.

Paksets
-------
This download contains the program and its base data, but no pakset. Put a
pakset folder (for example pak128.britain-ex) in THIS folder, beside
$APP_NAME.

Command-line tools
------------------
  ./simutrans-extended-server     dedicated server
  ./makeobj-extended              pakset compiler
  ./nettool-extended              server administration

Each of these is a small script that runs the real binary from inside
$APP_NAME/Contents/MacOS/. The binaries live in the bundle so that they
are covered by the same Developer ID signature and notarization ticket as the
game; you can also run them directly from there.

Checking this download
----------------------
  spctl --assess --type execute -vv $APP_NAME
  xcrun stapler validate $APP_NAME

Both should report a notarized Developer ID application.
README

# ---------------------------------------------------------------------------
# 6. Refuse to hand on a payload that still points at the build machine.
#
# This is the same check the unsigned nightly does, kept because it is the one
# failure that works perfectly on the runner and fails on every user's Mac.
# ---------------------------------------------------------------------------
echo
echo "-- portability check"
bad=0
while IFS= read -r -d '' f; do
	if ! file -b "$f" | grep -q 'Mach-O'; then
		continue
	fi
	refs=$(otool -L "$f" | awk 'NR>1 {print $1}')
	if grep -qE '^(@rpath/|/opt/homebrew/|/usr/local/)' <<<"$refs"; then
		echo "::error::$f still references a build-machine path:"
		otool -L "$f"
		bad=$((bad + 1))
	fi
	# No LC_RPATH at all, not merely no absolute one.  Checking only for
	# /opt/homebrew and /usr/local is what let a Homebrew bottle's own
	# @loader_path/../../../../opt/sdl3/lib through in the first rehearsal.
	rp=$(list_rpaths "$f")
	if [ -n "$rp" ]; then
		echo "::error::${f#"$app"/} still carries an LC_RPATH:"
		printf '%s\n' "$rp" | sed 's/^/::error::  /'
		bad=$((bad + 1))
	fi
done < <(find "$app" -type f -print0)

if [ "$bad" -gt 0 ]; then
	echo "::error::$bad file(s) would not run outside the build machine."
	exit 1
fi
echo "   every Mach-O resolves inside the bundle or in /usr/lib and /System,"
echo "   and none carries a search path any more"

echo
echo "payload assembled at $payload"
find "$payload" -maxdepth 1 -mindepth 1 | sed 's/^/   /' | sort
