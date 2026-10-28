#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Build the restrict_syscalls() syscall filter (docs/SANDBOX.md) into the
# kernel and libroot of the Haiku or Renku system this runs on, and package
# them as a replacement "haiku" system package.
#
#   build-sandbox-kernel.sh [build]   fetch the matching source, patch, build,
#                                     make the package (does not install it)
#   build-sandbox-kernel.sh install   install the package built above; it
#                                     takes effect at the next boot
#   build-sandbox-kernel.sh test      after that reboot: run the filter's own
#                                     test program
#   build-sandbox-kernel.sh restore   put the original haiku package back
#   build-sandbox-kernel.sh resolve <haiku package version>
#                                     only print the source commit a version
#                                     was built from (works on any OS with git)
#
# Options:
#   --workdir DIR   where sources, objects and output go
#                   (default: ~/sandbox-kernel-work; needs about 3 GB)
#   --source DIR    use this Haiku/Renku checkout instead of fetching one;
#                   it must be the revision the running system was built from
#   --rev COMMIT    fetch this commit instead of working it out
#   --repo URL      ... from this repository
#   --renku, --haiku
#                   which project the system comes from, when guessing wrong
#   --jobs N        parallel jobs for jam (default: CPU count)
#   --yes           do not ask before installing prerequisites or packages
#   --force         carry on past the checks that would stop the build

set -o pipefail

HAIKU_URL=https://review.haiku-os.org/haiku
RENKU_URL=https://github.com/RenkuOS/Source.git
KIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MARK="with the restrict_syscalls() syscall filter"

WORK=$HOME/sandbox-kernel-work
SOURCE= REV= REPO= PROJECT= JOBS= YES= FORCE=
COMMAND=build
ARGS=()

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
		build|install|test|restore|resolve) COMMAND=$1 ;;
		--workdir) WORK=$2; shift ;;
		--source)  SOURCE=$2; shift ;;
		--rev)     REV=$2; shift ;;
		--repo)    REPO=$2; shift ;;
		--renku)   PROJECT=renku ;;
		--haiku)   PROJECT=haiku ;;
		--jobs)    JOBS=$2; shift ;;
		--yes|-y)  YES=1 ;;
		--force)   FORCE=1 ;;
		-h|--help) sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
		-*) die "unknown option $1 (see --help)" ;;
		*)  ARGS+=("$1") ;;
	esac
	shift
done

OUT=$WORK/out

# The build appends to LIBRARY_PATH for its host tools; empty (ssh without a
# login shell), that leaves them without the system libraries.
if [ -z "$LIBRARY_PATH" ] && [ "$(uname -s)" = Haiku ]; then
	export LIBRARY_PATH="%A/lib:$HOME/config/non-packaged/lib:$HOME/config/lib"
	LIBRARY_PATH+=":/boot/system/non-packaged/lib:/boot/system/lib"
fi

confirm()
{
	[ -n "$YES" ] && return 0
	printf '%s [y/N] ' "$1"
	read -r answer
	case $answer in y|Y|yes) return 0 ;; esac
	return 1
}

on_haiku() { [ "$(uname -s)" = Haiku ]; }

# --- what is running --------------------------------------------------------

# The active system package: /boot/system/packages/haiku-<version>-<arch>.hpkg
# (haiku_devel, haiku_x86 and friends have an underscore, not a dash).
system_package()
{
	local found=()
	for f in /boot/system/packages/haiku-*.hpkg; do
		[ -e "$f" ] && found+=("$f")
	done
	[ ${#found[@]} -eq 1 ] \
		|| die "expected one haiku-*.hpkg in /boot/system/packages, found ${#found[@]}"
	echo "${found[0]}"
}

package_field()	# <package file> <field>
{
	package list -i "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" | head -1
}

# r1~beta6_hrev60072_339-1 -> "60072 339"; r1~beta6_hrev59866-1 -> "59866 0".
# The build writes `git describe` (hrevN-M-g<sha>, turned into hrevN+M) into
# the version with + and - replaced by _.
parse_version()
{
	local v=${1%-*}
	[[ $v =~ _hrev([0-9]+)(_([0-9]+))?$ ]] \
		|| die "cannot find an hrev in the package version \"$1\"; pass --rev"
	echo "${BASH_REMATCH[1]} ${BASH_REMATCH[3]:-0}"
}

looks_like_renku()
{
	[ "$PROJECT" = renku ] && return 0
	[ "$PROJECT" = haiku ] && return 1
	on_haiku || return 1
	pkgman list-repos 2>/dev/null | grep -qi renku && return 0
	grep -qis renku /boot/system/settings/package-repositories/* 2>/dev/null
}

# --- finding the source revision ---------------------------------------------

# Prints "<url> <commit>" for the first candidate repository and branch on
# which a commit is described as hrev<N>+<M>.
resolve()	# <hrev number> <count> <version>
{
	local hrev=$1 count=$2 version=$3
	local candidates=()

	if [ -n "$REPO" ]; then
		candidates+=("$REPO main" "$REPO master")
	else
		local beta
		[[ $version =~ ^r1~(beta[0-9]+) ]] && beta=r1${BASH_REMATCH[1]}
		if looks_like_renku; then
			candidates+=("$RENKU_URL main")
		fi
		# Haiku nightlies are built from master at a tag (count 0); releases
		# from their branch.
		[ -n "$beta" ] && candidates+=("$HAIKU_URL $beta")
		candidates+=("$HAIKU_URL master")
		looks_like_renku || candidates+=("$RENKU_URL main")
	fi

	if [ "$count" = 0 ]; then
		for c in "${candidates[@]}"; do
			local url=${c% *} sha
			sha=$(git ls-remote "$url" "refs/tags/hrev$hrev" "refs/tags/hrev$hrev^{}" \
				2>/dev/null | sort -k2 | tail -1 | cut -f1)
			if [ -n "$sha" ]; then
				echo "$url $sha"
				return 0
			fi
		done
		return 1
	fi

	# Count M commits past the tag: fetch commit history only (no trees or
	# files) and walk the branch's first-parent line, which is what nightly
	# and release builds are made from.
	mkdir -p "$WORK/history"
	for c in "${candidates[@]}"; do
		local url=${c% *} branch=${c#* }
		local dir=$WORK/history/$(echo "$url-$branch" | tr -c 'A-Za-z0-9\n' _)
		say "Looking for hrev$hrev+$count on $url $branch" >&2
		if [ -d "$dir" ]; then
			git -C "$dir" fetch -q origin "+refs/heads/$branch:refs/heads/$branch" \
				2>/dev/null || continue
		else
			git clone -q --bare --filter=tree:0 --no-tags --single-branch \
				--branch "$branch" "$url" "$dir" 2>/dev/null || { rm -rf "$dir"; continue; }
		fi
		git -C "$dir" fetch -q origin "+refs/tags/hrev$hrev:refs/tags/hrev$hrev" \
			2>/dev/null || continue
		local sha n
		for sha in $(git -C "$dir" rev-list --first-parent "$branch" "^hrev$hrev"); do
			n=$(git -C "$dir" rev-list --count "hrev$hrev..$sha")
			if [ "$n" = "$count" ]; then
				echo "$url $sha"
				return 0
			fi
			[ "$n" -lt "$count" ] && break
		done
	done
	return 1
}

# --- prerequisites -----------------------------------------------------------

need_tools()
{
	local arch=$1 missing=()
	local tools="git jam gcc bison flex wget python3 sed grep find package pkgman"
	[ "$arch" = x86_64 ] && tools="$tools nasm"
	for t in $tools; do
		command -v "$t" >/dev/null 2>&1 || missing+=("cmd:$t")
	done
	# configure links the kernel's C++ support from these
	if command -v gcc >/dev/null 2>&1 \
			&& [ ! -f "$(gcc -print-file-name=libsupc++.a)" ]; then
		missing+=(gcc_syslibs_devel)
	fi
	# ... and builds its host tools (package, rc, ...) against these
	local h
	for h in zlib:zlib.h zstd:zstd.h; do
		[ -f "/boot/system/develop/headers/${h#*:}" ] \
			|| missing+=("${h%%:*}_devel")
	done
	[ ${#missing[@]} -eq 0 ] && return 0
	say "Missing: ${missing[*]}"
	confirm "Install them with pkgman?" || die "cannot build without them"
	pkgman install -y "${missing[@]}" || die "pkgman could not install ${missing[*]}"
}

# --- build -------------------------------------------------------------------

pick_patch()	# <source dir>; prints the patch that applies there
{
	for p in "$KIT_DIR"/patches/r1beta6-and-later/*.patch \
			"$KIT_DIR"/patches/r1beta5/*.patch; do
		if git -C "$1" apply --check "$p" 2>/dev/null; then
			echo "$p"; return 0
		fi
		if git -C "$1" apply --check --reverse "$p" 2>/dev/null; then
			echo "applied:$p"; return 0
		fi
	done
	return 1
}

do_build()
{
	on_haiku || die "run this on the Haiku or Renku machine itself"

	local pkg arch version summary
	pkg=$(system_package)
	arch=$(package_field "$pkg" architecture)
	version=$(package_field "$pkg" version)
	summary=$(package_field "$pkg" summary)
	say "System package: $(basename "$pkg")"

	case $arch in
		x86_64) ;;
		arm64|riscv64)
			warn "$arch: the filter is checked in syscall_dispatcher() there, but it" \
				"has only been booted on x86_64" ;;
		*)
			[ -n "$FORCE" ] || die "$arch has no filter: restrict_syscalls() would" \
				"return B_NOT_SUPPORTED (pass --force to build it anyway)" ;;
	esac

	mkdir -p "$OUT/original" || die "cannot create $OUT"

	# Rebuilding on a system that already runs our package: start again from
	# the original, which the first run kept.
	local original=$pkg
	if [[ $summary == *"$MARK"* ]]; then
		original=$(ls "$OUT"/original/haiku-*.hpkg 2>/dev/null | head -1)
		[ -n "$original" ] || die "this system already runs a patched haiku" \
			"package and the original is not in $OUT/original"
		version=$(package_field "$original" version)
		say "Already patched; building again from $(basename "$original")"
	else
		cp -f "$pkg" "$OUT/original/" || die "cannot keep a copy of $pkg"
	fi

	need_tools "$arch"

	local hrev count revision
	read -r hrev count <<<"$(parse_version "$version")"
	revision=hrev$hrev
	[ "$count" != 0 ] && revision=hrev$hrev+$count
	say "Built from $revision"

	# The installed kernel carries the same string; if not, the version did not
	# come from this tree's describe and the guess below would be wrong.
	if ! grep -aq "$revision" "/boot/system/kernel_$arch" 2>/dev/null; then
		warn "/boot/system/kernel_$arch does not say $revision"
	fi

	local src
	if [ -n "$SOURCE" ]; then
		src=$(cd "$SOURCE" && pwd) || die "no such directory $SOURCE"
	else
		local url sha
		if [ -n "$REV" ]; then
			url=${REPO:-$( looks_like_renku && echo "$RENKU_URL" || echo "$HAIKU_URL")}
			sha=$REV
		else
			read -r url sha <<<"$(resolve "$hrev" "$count" "$version")"
			[ -n "$sha" ] || die "could not find the commit for $revision;" \
				"pass --rev <commit> (and --repo <url>)"
		fi
		say "Source: $url $sha"
		src=$WORK/src-${sha:0:12}
		if [ ! -f "$src/configure" ]; then
			rm -rf "$src"
			git init -q "$src" \
				&& git -C "$src" fetch --depth=1 "$url" "$sha" \
				&& git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD \
				|| die "could not fetch $sha from $url"
		fi
	fi

	local patch
	patch=$(pick_patch "$src") || die "none of the patches in $KIT_DIR/patches" \
		"applies to $src (Haiku older than R1/beta5, or a tree that has moved on)"
	if [[ $patch == applied:* ]]; then
		say "Patch already applied: $(basename "${patch#applied:}")"
	else
		say "Applying $(basename "$(dirname "$patch")")/$(basename "$patch")"
		git -C "$src" apply "$patch" || die "patch failed"
	fi

	local gen=$src/generated.sandbox
	mkdir -p "$gen"
	if [ ! -f "$gen/build/BuildConfig" ]; then
		say "Configuring"
		# On Haiku, configure takes the system's own compiler. Name the primary
		# architecture only, or a secondary one (x86 on x86_64) wants its own
		# gcc too.
		(cd "$gen" && ../configure --target-arch "$arch") || die "configure failed"
	fi

	local jobs=${JOBS:-$(sysinfo -cpu 2>/dev/null | sed -n 's/^\([0-9]*\) .*/\1/p' | head -1)}
	[ -n "$jobs" ] || jobs=2
	# A build package whose extraction failed (an interrupted run) is left as
	# an empty directory that jam then takes as done.
	[ -d "$gen/build_packages" ] && find "$gen/build_packages" -mindepth 1 \
		-maxdepth 1 -type d -empty -exec rmdir {} +
	say "Building kernel_$arch, libroot.so and syscall_filter_test (jam -j$jobs)"
	(cd "$gen" && HAIKU_REVISION=$revision jam -q -j"$jobs" \
			"<revisioned>kernel_$arch" "<revisioned>libroot.so" syscall_filter_test) \
		|| die "build failed; the log is above"

	local objects=$gen/objects/haiku/$arch/release
	local kernel=$objects/system/kernel/revisioned/kernel_$arch
	local libroot=$objects/system/libroot/revisioned/libroot.so
	local test=$objects/tests/system/kernel/syscall_filter_test
	for f in "$kernel" "$libroot" "$test"; do
		[ -f "$f" ] || die "the build did not produce $f"
	done
	grep -aq restrict_syscalls "$libroot" || die "libroot.so has no restrict_syscalls"

	say "Packaging"
	local stage=$WORK/stage
	rm -rf "$stage"
	mkdir -p "$stage/files/lib" "$stage/old"
	cp "$kernel" "$stage/files/kernel_$arch"
	cp "$libroot" "$stage/files/lib/libroot.so"
	cp "$test" "$OUT/syscall_filter_test"

	# Both files must already be where we are about to put them.
	package extract -C "$stage/old" "$original" .PackageInfo "kernel_$arch" lib/libroot.so \
		|| die "$(basename "$original") does not hold kernel_$arch and lib/libroot.so"

	# Same name and version, one revision up, so pkgman sees an update; the
	# "haiku = <version>" it provides is left alone, so haiku_devel and the
	# rest are still satisfied.
	local rev=${version##*-} newversion
	newversion=${version%-*}-$((rev + 1))
	sed -e "s|^\([[:space:]]*version[[:space:]]*\).*|\1$newversion|" \
		-e "s|^\([[:space:]]*summary[[:space:]]*\)\"\(.*\)\"|\1\"\2 ($MARK)\"|" \
		"$stage/old/.PackageInfo" > "$stage/PackageInfo"
	grep -q "$newversion" "$stage/PackageInfo" || die "could not set the version"

	local new=$OUT/haiku-$newversion-$arch.hpkg
	rm -f "$new"
	cp "$original" "$new"
	package add -f -q -i "$stage/PackageInfo" -C "$stage/files" "$new" \
			"kernel_$arch" lib/libroot.so \
		|| die "package add failed"
	[ "$(package_field "$new" version)" = "$newversion" ] \
		|| die "the new package does not read back as $newversion"

	echo "$new" > "$OUT/package-path"
	say "Done"
	cat <<EOF

  Package:  $new
  Test:     $OUT/syscall_filter_test
  Original: $OUT/original/$(basename "$original")

Next:   $0 install     (then reboot)
EOF
}

# --- install / restore / test ------------------------------------------------

pkgman_install()	# <hpkg>
{
	on_haiku || die "run this on the Haiku or Renku machine itself"
	say "pkgman install $(basename "$1")"
	echo "If the new kernel does not boot: hold Shift (or Space) at boot, choose"
	echo "\"Select safe mode options\" -> \"Select system state\", and pick the"
	echo "state from before this install."
	confirm "Go ahead?" || exit 1
	pkgman install -y "$1" || die "pkgman failed"
	echo
	say "Reboot to start the new kernel."
}

do_install()
{
	local new
	new=$(cat "$OUT/package-path" 2>/dev/null)
	[ -f "$new" ] || die "nothing built yet in $OUT; run $0 build first"
	pkgman_install "$new"
}

do_restore()
{
	local original
	original=$(ls "$OUT"/original/haiku-*.hpkg 2>/dev/null | head -1)
	[ -f "$original" ] || die "no original package in $OUT/original"
	# A lower revision than the installed one: pkgman treats a file named on
	# its command line as what is wanted.
	pkgman_install "$original"
}

do_test()
{
	on_haiku || die "run this on the Haiku or Renku machine itself"
	local summary
	summary=$(package_field "$(system_package)" summary)
	[[ $summary == *"$MARK"* ]] \
		|| warn "the active haiku package is not the patched one (rebooted yet?)"
	grep -aq restrict_syscalls /boot/system/lib/libroot.so \
		|| die "/boot/system/lib/libroot.so has no restrict_syscalls(); reboot first"
	[ -x "$OUT/syscall_filter_test" ] || die "no $OUT/syscall_filter_test"
	say "syscall_filter_test"
	"$OUT/syscall_filter_test"
}

case $COMMAND in
	build)   do_build ;;
	install) do_install ;;
	restore) do_restore ;;
	test)    do_test ;;
	resolve)
		[ ${#ARGS[@]} -eq 1 ] || die "usage: $0 resolve <haiku package version>"
		read -r h c <<<"$(parse_version "${ARGS[0]}")"
		resolve "$h" "$c" "${ARGS[0]}" || die "not found"
		;;
esac
