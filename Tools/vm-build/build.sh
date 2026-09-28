#!/usr/bin/env bash
#
# build.sh — build manager for the Vision Miner RepRapFirmware line.
#
# It lives inside the firmware repository, so a checkout carries everything
# needed to reproduce its own binaries: the dependency pins (repos.conf), the
# buildable targets (targets.conf) and this driver. The firmware repo is the
# only thing you clone by hand; bootstrap fetches the rest next to it.
#
#   build.sh doctor              Check the environment and report what is missing
#   build.sh bootstrap           Fetch toolchains + dependency repos, install CrcAppender
#   build.sh build   [target…]   Incremental build (default target from targets.conf)
#   build.sh rebuild [target…]   Clean build from a fresh Eclipse workspace
#   build.sh release-build [t…]  Reproducible build of the current commit
#   build.sh clean   [--deps]    Remove build outputs and Eclipse metadata
#   build.sh targets             List the configured targets
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Layout ------------------------------------------------------------------
# The firmware repo is located from this script rather than from $PWD, so every
# command works from anywhere.
if ! RRF_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
	RRF_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

# The workspace holds everything that is not the firmware: toolchains, the
# dependency repositories and Eclipse's own metadata. It is always outside the
# repo, so `git clean` and `git status` never see it.
#   1. $RRF_WS wins, for CI and for unusual layouts.
#   2. The canonical layout <ws>/repos/RepRapFirmware is recognised.
#   3. Otherwise a sibling directory next to the repo.
if [ -n "${RRF_WS:-}" ]; then
	WS="$RRF_WS"
elif [ "$(basename "$(dirname "$RRF_ROOT")")" = "repos" ]; then
	WS="$(dirname "$(dirname "$RRF_ROOT")")"
else
	WS="$(dirname "$RRF_ROOT")/vm-rrf-workspace"
fi

DEPS_DIR="${WS}/repos"
TOOLS_DIR="${WS}/tools"
BIN_DIR="${TOOLS_DIR}/bin"
ECLIPSE_DATA="${WS}/.eclipse-ws"
ARM_GCC_DIR="${TOOLS_DIR}/arm-gcc"
XTENSA_GCC_DIR="${TOOLS_DIR}/xtensa-gcc"
ECLIPSE_DIR="${TOOLS_DIR}/eclipse"

for conf in repos.conf targets.conf; do
	[ -r "${SCRIPT_DIR}/${conf}" ] || { printf 'build.sh: missing %s\n' "${SCRIPT_DIR}/${conf}" >&2; exit 1; }
	# shellcheck source=/dev/null
	. "${SCRIPT_DIR}/${conf}"
done

VERSION_HEADER="${RRF_ROOT}/src/Version.h"
BUILD_LOG="${WS}/last-build.log"

# --- Host --------------------------------------------------------------------
# Toolchains are pinned per host in repos.conf. HOST is empty on a host that
# has no pins. A shell running under Rosetta 2 reports x86_64 on Apple silicon;
# the machine underneath is what the native toolchain has to match.
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
if [ "$HOST_OS" = "Darwin" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then HOST_ARCH="arm64"; fi
case "${HOST_OS}-${HOST_ARCH}" in
	Linux-x86_64) HOST="linux-x86_64" ;;
	Darwin-arm64) HOST="darwin-arm64" ;;
	*)            HOST="" ;;
esac
SUPPORTED_HOSTS="linux-x86_64, darwin-arm64"

# Quiet build output by default; V=1 or --verbose shows everything Eclipse says.
VERBOSE="no"
if [ "${V:-0}" = "1" ]; then VERBOSE="yes"; fi

# --- Logging -----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
	C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

section() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"; }
info()    { printf '%s  •%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
ok()      { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s  ‼ %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()     { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET"; }
die()     { printf '\n%s✗ %s%s\n' "${C_BOLD}${C_RED}" "$*" "$C_RESET" >&2; exit 1; }

trap 's=$?; [ $s -ne 0 ] && printf "\n%s✗ Aborted (exit %s) at line %s: %s%s\n" \
	"${C_BOLD}${C_RED}" "$s" "$LINENO" "$BASH_COMMAND" "$C_RESET" >&2' ERR

have() { command -v "$1" >/dev/null 2>&1; }

# --- Config accessors --------------------------------------------------------
# Every dependency line is "name|url|ref|sha|kind"; every target line is
# "config|artifact|extensions|description".

dep_dir() { printf '%s/%s' "$DEPS_DIR" "$1"; }

# Echo the target line for a configuration name, or fail if it is not configured.
target_entry() {
	local want="$1" entry name
	for entry in "${TARGETS[@]}"; do
		IFS='|' read -r name _ _ _ <<< "$entry"
		if [ "$name" = "$want" ]; then printf '%s' "$entry"; return 0; fi
	done
	return 1
}

# Echo the artifact files a target ships, one per line.
target_artifacts() {
	local entry name base exts ext
	entry="$(target_entry "$1")" || return 1
	IFS='|' read -r name base exts _ <<< "$entry"
	local IFS=','
	for ext in $exts; do printf '%s/%s/%s.%s\n' "$RRF_ROOT" "$name" "$base" "$ext"; done
}

# Echo this host's line from a list of "host|url|checksum" archive pins, or fail
# when the host has none.
host_archive() {
	local entry host
	for entry in "$@"; do
		IFS='|' read -r host _ _ <<< "$entry"
		if [ "$host" = "$HOST" ]; then printf '%s' "$entry"; return 0; fi
	done
	return 1
}

# --- Tool discovery ----------------------------------------------------------
# Eclipse is never executed to probe it: without -application it opens the
# workspace-chooser GUI and blocks. Version and CDT presence come from files.

# Resolve symlinks down to the real file, as GNU `readlink -f` does; older macOS
# releases have no -f.
resolve_path() {
	local p="$1" link
	while [ -L "$p" ]; do
		link="$(readlink "$p")"
		case "$link" in
			/*) p="$link" ;;
			*)  p="$(dirname "$p")/${link}" ;;
		esac
	done
	printf '%s/%s' "$(cd -P "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
}

# The launcher of the pinned copy in tools/eclipse. The Linux archive's top
# directory is stripped when it is unpacked; the macOS archive is an Eclipse.app
# bundle and is unpacked whole.
pinned_eclipse_bin() {
	if [ "$HOST_OS" = "Darwin" ]; then printf '%s' "${ECLIPSE_DIR}/Eclipse.app/Contents/MacOS/eclipse"
	else printf '%s' "${ECLIPSE_DIR}/eclipse"; fi
}

eclipse_bin() {
	local app
	if [ -x "$(pinned_eclipse_bin)" ]; then pinned_eclipse_bin; return 0; fi
	if have eclipse; then command -v eclipse; return 0; fi
	# On macOS Eclipse is installed as an application bundle, with nothing on PATH.
	[ "$HOST_OS" = "Darwin" ] || return 1
	for app in /Applications/Eclipse.app "${HOME}/Applications/Eclipse.app"; do
		if [ -x "${app}/Contents/MacOS/eclipse" ]; then printf '%s' "${app}/Contents/MacOS/eclipse"; return 0; fi
	done
	return 1
}

# The installation directory: the one holding plugins/ and .eclipseproduct.
eclipse_home() {
	local bin dir; bin="$(eclipse_bin)" || return 1
	dir="$(dirname "$(resolve_path "$bin")")"
	# In a macOS bundle the launcher is Contents/MacOS/eclipse and the
	# installation it starts is Contents/Eclipse.
	case "$dir" in */Contents/MacOS) dir="${dir%/MacOS}/Eclipse" ;; esac
	printf '%s' "$dir"
}

eclipse_version() {
	local home; home="$(eclipse_home)" || return 1
	[ -f "${home}/.eclipseproduct" ] || return 1
	sed -n 's/^version=//p' "${home}/.eclipseproduct"
}

eclipse_has_cdt() {
	local home; home="$(eclipse_home)" || return 1
	compgen -G "${home}/plugins/*cdt.managedbuilder.core*" >/dev/null 2>&1 ||
		compgen -G "${home}/dropins/*/plugins/*cdt.managedbuilder.core*" >/dev/null 2>&1
}

arm_gcc() {
	if [ -x "${ARM_GCC_DIR}/bin/arm-none-eabi-gcc" ]; then printf '%s' "${ARM_GCC_DIR}/bin/arm-none-eabi-gcc"
	elif have arm-none-eabi-gcc; then command -v arm-none-eabi-gcc
	else return 1; fi
}

xtensa_gcc() {
	if [ -x "${XTENSA_GCC_DIR}/bin/xtensa-lx106-elf-gcc" ]; then printf '%s' "${XTENSA_GCC_DIR}/bin/xtensa-lx106-elf-gcc"
	elif have xtensa-lx106-elf-gcc; then command -v xtensa-lx106-elf-gcc
	else return 1; fi
}

dotnet6_present() { have dotnet && dotnet --list-runtimes 2>/dev/null | grep -q "Microsoft.NETCore.App 6\."; }

rosetta_present() { /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; }

# CrcAppender is vendored for x86_64 only, so on Apple silicon it runs under
# Rosetta 2 and needs the x64 .NET 6 runtime, which is installed apart from the
# arm64 one. Echo that runtime's root: $DOTNET_ROOT_X64, the location recorded
# in /etc/dotnet/install_location_x64, or Microsoft's default for it.
dotnet6_x64_root() {
	local root
	for root in "${DOTNET_ROOT_X64:-}" "$(cat /etc/dotnet/install_location_x64 2>/dev/null)" /usr/local/share/dotnet/x64; do
		[ -n "$root" ] || continue
		if compgen -G "${root}/shared/Microsoft.NETCore.App/6.*" >/dev/null 2>&1; then printf '%s' "$root"; return 0; fi
	done
	return 1
}

crc_runtime_present() {
	if [ "$HOST" = "darwin-arm64" ]; then rosetta_present && dotnet6_x64_root >/dev/null
	else dotnet6_present; fi
}

# The vendored CrcAppender this host runs. The repository carries no arm64 build.
crcappender_src() {
	if [ "$HOST_OS" = "Darwin" ]; then printf '%s' "${RRF_ROOT}/Tools/CrcAppender/macos-x86_64/CrcAppender"
	else printf '%s' "${RRF_ROOT}/Tools/CrcAppender/linux-x86_64/CrcAppender"; fi
}

current_version() { sed -n 's/^# *define[[:space:]]*MAIN_VERSION[[:space:]]*"\(.*\)".*/\1/p' "$VERSION_HEADER"; }

# --- Downloads ---------------------------------------------------------------
# A download is only trusted once its sha256 is pinned in repos.conf. Until then
# the fetched value is printed so it can be pinned deliberately.
# Checksums are pinned as "<algo>:<hex>"; a bare value is read as sha256. Vendors
# publish different algorithms — ARM publish sha256, Eclipse sha512 — and pinning
# what they publish avoids downloading a release just to hash it.
#
# GNU coreutils provide sha256sum and sha512sum; macOS provides shasum, which
# prints the same "<hex>  <file>" line.
sha_line() {
	if have "sha${1}sum"; then "sha${1}sum" "$2"
	else shasum -a "$1" "$2"; fi
}

checksum_of() {
	case "$2" in
		sha256) sha_line 256 "$1" | cut -d' ' -f1 ;;
		sha512) sha_line 512 "$1" | cut -d' ' -f1 ;;
		*) die "unsupported checksum algorithm '$2'" ;;
	esac
}

fetch_verify() {
	local label="$1" url="$2" dest="$3" pin="$4" algo="sha256" want="" got
	case "$pin" in
		sha256:*) want="${pin#sha256:}" ;;
		sha512:*) algo="sha512"; want="${pin#sha512:}" ;;
		*:*)      die "${label}: unrecognised checksum pin '${pin}'" ;;
		*)        want="$pin" ;;
	esac
	info "Downloading ${label}…"
	if have curl; then
		curl -fL --retry 3 --connect-timeout 30 -o "$dest" "$url" || { rm -f "$dest"; die "Failed to download ${label} from ${url}"; }
	elif have wget; then
		wget --tries=3 --timeout=30 -O "$dest" "$url" || { rm -f "$dest"; die "Failed to download ${label} from ${url}"; }
	else
		die "Neither curl nor wget is available."
	fi
	got="$(checksum_of "$dest" "$algo")"
	if [ -n "$want" ]; then
		[ "$got" = "$want" ] || { rm -f "$dest"; die "${label}: ${algo} mismatch
  expected ${want}
  got      ${got}"; }
		ok "${label}: ${algo} verified"
	else
		warn "${label}: checksum not pinned — add this to repos.conf:"
		printf '      sha256:%s\n' "$(checksum_of "$dest" sha256)"
	fi
}

install_toolchain() {
	local label="$1" url="$2" dir="$3" probe="$4" want="$5"
	if [ -x "${dir}/bin/${probe}" ]; then
		info "${label} already installed — refreshing symlinks"
		ln -sf "${dir}/bin/"* "${BIN_DIR}/"
		ok "${label} ready"
		return
	fi
	mkdir -p "$dir"
	local archive="${TOOLS_DIR}/.dl-${probe}.archive"
	fetch_verify "$label" "$url" "$archive" "$want"
	info "Extracting ${label}…"
	tar -xf "$archive" -C "$dir" --strip-components=1
	rm -f "$archive"
	[ -x "${dir}/bin/${probe}" ] || die "${label} extracted but '${probe}' is missing — the archive layout may have changed."
	ln -sf "${dir}/bin/"* "${BIN_DIR}/"
	ok "${label} installed"
}

setup_toolchains() {
	local with_wifi_fw="$1" with_eclipse="$2" entry url pin
	section "Toolchains"
	mkdir -p "$BIN_DIR"
	entry="$(host_archive "${ARM_GCC_ARCHIVES[@]}")" || die "repos.conf pins no ARM GCC archive for ${HOST}."
	IFS='|' read -r _ url pin <<< "$entry"
	install_toolchain "ARM GCC ${ARM_GCC_VERSION}" "$url" "$ARM_GCC_DIR" "arm-none-eabi-gcc" "$pin"
	if [ "$with_wifi_fw" = "yes" ]; then
		entry="$(host_archive "${XTENSA_GCC_ARCHIVES[@]}")" || die "repos.conf pins no Xtensa GCC archive for ${HOST} — the WiFi-module firmware cannot be built on this host."
		IFS='|' read -r _ url pin <<< "$entry"
		install_toolchain "Xtensa GCC" "$url" "$XTENSA_GCC_DIR" "xtensa-lx106-elf-gcc" "$pin"
	else
		info "Xtensa toolchain skipped (only the WiFi-module firmware needs it; pass --with-wifi-fw)"
	fi

	# The pinned Eclipse is a 400 MB download, so it is fetched only when the
	# machine has none — which is the case on a CI runner — or when asked for.
	url=""; pin=""
	if entry="$(host_archive "${ECLIPSE_ARCHIVES[@]}")"; then IFS='|' read -r _ url pin <<< "$entry"; fi
	if [ -x "$(pinned_eclipse_bin)" ]; then
		ok "Eclipse already installed in tools/eclipse"
	elif [ -z "$url" ]; then
		info "No Eclipse archive pinned for ${HOST} — using the Eclipse installed on this machine"
	elif [ "$with_eclipse" != "yes" ] && eclipse_has_cdt 2>/dev/null; then
		info "Eclipse with CDT found on this machine — skipping the pinned copy (pass --with-eclipse to install it anyway)"
	else
		mkdir -p "$ECLIPSE_DIR"
		local archive="${TOOLS_DIR}/.dl-eclipse.archive" strip=1
		fetch_verify "Eclipse ${ECLIPSE_EXPECTED_VERSION}" "$url" "$archive" "$pin"
		info "Extracting Eclipse…"
		if [ "$HOST_OS" = "Darwin" ]; then strip=0; fi
		tar -xf "$archive" -C "$ECLIPSE_DIR" --strip-components="$strip"
		rm -f "$archive"
		[ -x "$(pinned_eclipse_bin)" ] || die "Eclipse extracted but $(pinned_eclipse_bin) is missing — the archive layout may have changed."
		ok "Eclipse installed into tools/eclipse"
	fi
}

# --- Dependency repositories -------------------------------------------------
checkout_ref() {
	local dir="$1" ref="$2"
	if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
		# A branch: check it out as a tracking branch, without discarding local work.
		git -C "$dir" checkout --quiet "$ref" 2>/dev/null || git -C "$dir" checkout --quiet -b "$ref" "origin/${ref}"
		git -C "$dir" merge --ff-only --quiet "origin/${ref}" 2>/dev/null || warn "$(basename "$dir"): cannot fast-forward ${ref}, left as is"
	else
		# A tag or commit: detached HEAD is what we want for a pin.
		git -C "$dir" checkout --quiet "$ref"
	fi
}

setup_deps() {
	local do_sync="$1" with_wifi_fw="$2"
	section "Dependency repositories"
	mkdir -p "$DEPS_DIR"

	local entry name url ref sha kind dir
	for entry in "${DEPS[@]}"; do
		IFS='|' read -r name url ref sha kind <<< "$entry"
		[ "$kind" = "wifi-fw" ] && [ "$with_wifi_fw" != "yes" ] && continue
		dir="$(dep_dir "$name")"

		if [ ! -d "${dir}/.git" ]; then
			[ -e "$dir" ] && { warn "${name}/ exists but is not a git repo — skipped"; continue; }
			info "Cloning ${name}…"
			git clone --quiet "$url" "$dir"
			checkout_ref "$dir" "$ref"
		else
			git -C "$dir" fetch --all --tags --quiet 2>/dev/null || warn "${name}: fetch failed (offline?) — using local state"
			if [ -n "$(git -C "$dir" status --porcelain)" ]; then
				warn "${name}: has local changes — left untouched"
			elif [ "$do_sync" = "yes" ]; then
				checkout_ref "$dir" "$ref"
			fi
		fi
		# A dependency that is off its pin is reported, not fatal: bootstrap is
		# exactly the command you run to put it back.
		report_dep "$name" "$ref" "$sha" || true
	done
}

# Print one dependency's state and return non-zero when it is off its pin.
report_dep() {
	local name="$1" ref="$2" sha="$3" dir head
	dir="$(dep_dir "$name")"
	if [ ! -d "${dir}/.git" ]; then err "${name} — missing (wants ${ref})"; return 1; fi
	head="$(git -C "$dir" rev-parse HEAD)"
	if [ -n "$(git -C "$dir" status --porcelain)" ]; then
		warn "${name} — ${head:0:12} with local changes"
		return 1
	fi
	if [ -n "$sha" ] && [ "$head" != "$sha" ]; then
		err "${name} — at ${head:0:12}, pinned to ${sha:0:12} (run 'bootstrap --sync')"
		return 1
	fi
	ok "${name} — $(git -C "$dir" describe --tags --always 2>/dev/null || printf '%s' "${head:0:12}")"
	return 0
}

verify_dep_pins() {
	local entry name ref sha kind rc=0
	for entry in "${DEPS[@]}"; do
		IFS='|' read -r name _ ref sha kind <<< "$entry"
		[ "$kind" = "core" ] || continue
		report_dep "$name" "$ref" "$sha" || rc=1
	done
	return $rc
}

setup_crcappender() {
	section "CrcAppender"
	local src; src="$(crcappender_src)"
	[ -f "$src" ] || die "CrcAppender not found at ${src}"
	mkdir -p "$BIN_DIR"
	install -m 755 "$src" "${BIN_DIR}/CrcAppender"
	ok "CrcAppender installed into tools/bin"
	if [ "$HOST" = "darwin-arm64" ]; then
		crc_runtime_present || warn "Rosetta 2 or the x64 .NET 6 runtime is missing — CrcAppender will fail during the post-build step (see 'build.sh doctor')"
	else
		crc_runtime_present || warn ".NET 6 runtime missing — CrcAppender will fail during the post-build step"
	fi
}

# --- Build output ------------------------------------------------------------
# Eclipse CDT generates makefiles that echo three lines and a ~2 KB command per
# source file, which buries compiler warnings. This rewrites that into the shape
# the kernel build uses:
#
#   CXX     src/Movement/DDA.cpp
#   LD      Duet3Firmware_MB6HC.elf
#
# Only recognised noise is dropped; every other line is passed through verbatim,
# so a new Eclipse version can make the output verbose again but can never hide a
# diagnostic. The full log is always written to $BUILD_LOG.
#
# The file being compiled is read from the command line rather than from the
# "Building file:" echo above it: with make -j those echoes interleave between
# jobs, and a line-by-line rule cannot mispair what it never pairs.
build_filter() {
	awk '
	function emit(tool, what) { printf "  %-7s %s\n", tool, what; fflush() }
	function base(p,   n, a) { n = split(p, a, "/"); return a[n] }
	function scoped(p) { return (project != "" && project != "RepRapFirmware") ? project "/" p : p }

	/^INFO: / { next }
	/ org\.(apache|eclipse|slf4j)\./ { next }
	index($0, "Opening \047") == 1 { next }
	# Printed instead of "Opening" when the workspace is created from scratch,
	# and it names nothing at all; build.sh lists the projects itself.
	/^Create\.$/ { next }
	# Only make\047s chatter is dropped. Anything else it says — "*** Error 2",
	# "No rule to make target" — is how a build reports failure.
	/^make(\[[0-9]+\])?: (Entering|Leaving) directory/ { next }
	/^make(\[[0-9]+\])?: Nothing to be done/ { next }
	# The command echo: "make -j16 all", "make clean". Anything make says about
	# a problem has a colon after its name and does not match this.
	/^make([ ]+-[^ ]+)*[ ]+[A-Za-z][A-Za-z0-9._-]*[ ]*$/ { next }
	/^[ \t]*$/ { next }

	# Which project the following lines belong to.
	index($0, "**** ") && index($0, " for project ") {
		p = substr($0, index($0, " for project ") + 13)
		sub(/ \*\*\*\*.*$/, "", p)
		project = p
		next
	}

	# A clean per-project summary says nothing; one with errors or warnings stays.
	/Build Finished\. 0 errors, 0 warnings/ { next }

	/^Building file: / { next }
	/^Building target: / { next }
	/^Invoking: / { next }
	/^Finished building/ { next }
	/^Generating binary file$/ { next }
	/^Firmware binary: / { next }
	/^arm-none-eabi-ar: creating / { next }
	index($0, "Saving workspace.") == 1 { next }

	/^CRC32 = / { emit("CRC", $3); next }

	# The clean recipe echoes every object it removes — hundreds of paths on one
	# line. The directory being cleaned is all that is worth reading.
	/^rm -rf / {
		if (NF < 3) { print; fflush(); next }
		p = $3
		sub(/^\.\//, "", p)
		if (index(p, "/") > 0) sub(/\/[^\/]*$/, "", p)
		emit("CLEAN", scoped(p))
		next
	}

	# Tool invocations. A diagnostic such as "arm-none-eabi-g++: error: …" has a
	# colon where a command has a space, so it does not match here and is printed.
	/^arm-none-eabi-[a-zA-Z+_-]+ / {
		cmd = $1
		n = 0; rest = $0
		while (match(rest, /"[^"]*"/)) {
			q[++n] = substr(rest, RSTART + 1, RLENGTH - 2)
			rest = substr(rest, RSTART + RLENGTH)
		}
		if (cmd ~ /-objcopy$/ && n >= 1) { emit("BIN", base(q[n])); next }
		if (cmd ~ /-ar$/ && n >= 1)      { emit("AR",  base(q[1])); next }
		if (index($0, " -c ") > 0 && n >= 1) {
			src = q[n]
			sub(/^\.\.\//, "", src)
			tool = "CC"
			if (src ~ /\.(cpp|cc|cxx)$/) tool = "CXX"
			else if (src ~ /\.[Ss]$/)    tool = "AS"
			emit(tool, scoped(src))
			next
		}
		if (match($0, /-o "[^"]+"/)) { emit("LD", base(substr($0, RSTART + 4, RLENGTH - 5))); next }
		print; fflush(); next
	}

	{ print; fflush() }
	'
}

# --- Eclipse -----------------------------------------------------------------
run_eclipse() {
	local mode="$1"; shift
	local ecl gcc entry name dir cfg x64root
	ecl="$(eclipse_bin)" || die "Eclipse not found — install Eclipse CDT, or pin an Eclipse archive for ${HOST:-this host} in repos.conf and re-run bootstrap."
	eclipse_has_cdt || die "Eclipse at $(eclipse_home) has no CDT managed-build plugin."
	gcc="$(arm_gcc)" || die "ARM toolchain missing — run 'build.sh bootstrap'."

	local args=(--launcher.suppressErrors -nosplash
		-application org.eclipse.cdt.managedbuilder.core.headlessbuild
		-data "$ECLIPSE_DATA"
		-E "ArmGccPath=$(dirname "$gcc")")

	# Import exactly the projects we pin. -importAll on a directory would also
	# pull in whatever else happens to sit there, and two projects with the same
	# name make the workspace unusable.
	local -a imported=("RepRapFirmware")
	args+=(-import "$RRF_ROOT")
	for entry in "${DEPS[@]}"; do
		IFS='|' read -r name _ _ _ _ <<< "$entry"
		dir="$(dep_dir "$name")"
		if [ -f "${dir}/.project" ]; then
			args+=(-import "$dir")
			imported+=("$name")
		fi
	done

	for cfg in "$@"; do args+=("$mode" "RepRapFirmware/${cfg}"); done

	export PATH="${BIN_DIR}:${PATH}"
	# The post-build step runs CrcAppender under Rosetta 2. Name the x64 runtime
	# explicitly, so a DOTNET_ROOT meant for the arm64 one cannot mislead it.
	if [ "$HOST" = "darwin-arm64" ] && x64root="$(dotnet6_x64_root)"; then export DOTNET_ROOT_X64="$x64root"; fi
	info "Eclipse: ${ecl} ($(eclipse_version 2>/dev/null || printf 'unknown version'))"
	info "ARM GCC: ${gcc} ($("$gcc" -dumpversion))"
	info "projects: ${imported[*]}"

	# Both streams are captured, so the log holds everything in the order it
	# happened. pipefail is on, so a failing Eclipse still fails the pipeline.
	mkdir -p "$WS"
	if [ "$VERBOSE" = "yes" ]; then
		"$ecl" "${args[@]}" 2>&1 | tee "$BUILD_LOG"
	else
		"$ecl" "${args[@]}" 2>&1 | tee "$BUILD_LOG" | build_filter
	fi
	info "full log: ${BUILD_LOG}"
}

# Resolve the target list for a build command into RESOLVED_TARGETS. A global
# array rather than stdout: die() inside a process substitution would only kill
# the subshell, leaving the caller with an empty and silently wrong target list.
declare -a RESOLVED_TARGETS=()
resolve_targets() {
	RESOLVED_TARGETS=()
	if [ "$#" -eq 0 ]; then RESOLVED_TARGETS=("$DEFAULT_TARGET"); return; fi
	local cfg
	for cfg in "$@"; do
		target_entry "$cfg" >/dev/null || die "Unknown target '${cfg}'. Configured targets: $(list_target_names | paste -sd' ' -)"
		RESOLVED_TARGETS+=("$cfg")
	done
}

list_target_names() {
	local entry name
	for entry in "${TARGETS[@]}"; do IFS='|' read -r name _ _ _ <<< "$entry"; printf '%s\n' "$name"; done
}

# Report every file the given targets promise. Returns non-zero when one is
# missing, so a build can never be reported as successful without its binary.
report_artifacts() {
	local cfg file rc=0
	for cfg in "$@"; do
		while read -r file; do
			if [ -f "$file" ]; then
				ok "$(basename "$file") — $(du -h "$file" | cut -f1)  sha256 $(sha_line 256 "$file" | cut -c1-16)…"
				info "   ${file}"
			else
				err "expected artifact missing: ${file}"
				rc=1
			fi
		done < <(target_artifacts "$cfg")
	done
	return $rc
}

# --- Commands ----------------------------------------------------------------
cmd_doctor() {
	local problems=0

	section "Paths"
	info "firmware   ${RRF_ROOT}"
	info "workspace  ${WS}"
	info "deps       ${DEPS_DIR}"
	info "toolchains ${TOOLS_DIR}"
	info "eclipse ws ${ECLIPSE_DATA}"

	section "Environment"
	if [ -n "$HOST" ]; then
		ok "Platform: ${HOST}"
	else
		err "Platform: ${HOST_OS} ${HOST_ARCH} — toolchains are pinned for ${SUPPORTED_HOSTS} only"; problems=$((problems + 1))
	fi

	# GNU tar runs xz to unpack the ARM toolchain; the bsdtar macOS ships
	# decompresses it by itself.
	local missing=() c
	for c in git tar make; do have "$c" || missing+=("$c"); done
	[ "$HOST_OS" = "Darwin" ] || have xz || missing+=("xz")
	{ have sha256sum && have sha512sum; } || have shasum || missing+=("sha256sum and sha512sum, or shasum")
	have curl || have wget || missing+=("curl or wget")
	if [ ${#missing[@]} -eq 0 ]; then ok "Base tools present"
	else err "Missing base tools: ${missing[*]}"; problems=$((problems + 1)); fi

	# /usr/bin/make and /usr/bin/git are only stubs until the Command Line Tools
	# are installed, so finding them on PATH proves nothing.
	if [ "$HOST_OS" = "Darwin" ]; then
		if xcode-select -p >/dev/null 2>&1; then ok "Xcode Command Line Tools present"
		else err "Xcode Command Line Tools missing — run 'xcode-select --install'"; problems=$((problems + 1)); fi
	fi

	local ev
	if ev="$(eclipse_version 2>/dev/null)"; then
		if eclipse_has_cdt; then
			if [ "$ev" = "$ECLIPSE_EXPECTED_VERSION" ]; then ok "Eclipse ${ev} with CDT"
			else warn "Eclipse ${ev} with CDT — this line was validated with ${ECLIPSE_EXPECTED_VERSION}"; fi
		else
			err "Eclipse ${ev} has no CDT managed-build plugin"; problems=$((problems + 1))
		fi
	else
		err "Eclipse not found"; problems=$((problems + 1))
	fi

	if [ "$HOST" = "darwin-arm64" ]; then
		local x64root
		if rosetta_present; then ok "Rosetta 2 present (CrcAppender is an x86_64 program)"
		else err "Rosetta 2 missing — CrcAppender is an x86_64 program; run 'softwareupdate --install-rosetta'"; problems=$((problems + 1)); fi
		if x64root="$(dotnet6_x64_root)"; then ok ".NET 6 x64 runtime present in ${x64root} (CrcAppender)"
		else err ".NET 6 x64 runtime missing — CrcAppender needs the x64 build, not the arm64 one (or set DOTNET_ROOT_X64)"; problems=$((problems + 1)); fi
	elif dotnet6_present; then ok ".NET 6 runtime present (CrcAppender)"
	else err ".NET 6 runtime missing — CrcAppender needs it"; problems=$((problems + 1)); fi

	local gcc v
	if gcc="$(arm_gcc)"; then
		v="$("$gcc" -dumpversion)"
		if [ "$v" = "$ARM_GCC_VERSION" ]; then
			ok "ARM GCC ${v}"
			[ "$gcc" = "${ARM_GCC_DIR}/bin/arm-none-eabi-gcc" ] || warn "using the system compiler at ${gcc}; release builds require the pinned copy in tools/"
		else
			err "ARM GCC ${v} at ${gcc}, pinned to ${ARM_GCC_VERSION}"; problems=$((problems + 1))
		fi
	else
		err "ARM GCC missing — run 'build.sh bootstrap'"; problems=$((problems + 1))
	fi

	[ -x "${BIN_DIR}/CrcAppender" ] && ok "CrcAppender installed" || warn "CrcAppender not installed — run 'build.sh bootstrap'"

	section "Dependencies"
	verify_dep_pins || problems=$((problems + 1))

	section "Firmware"
	local ver branch tag
	ver="$(current_version)"
	branch="$(git -C "$RRF_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')"
	tag="$(git -C "$RRF_ROOT" describe --tags --exact-match HEAD 2>/dev/null || printf '')"
	ok "MAIN_VERSION ${ver}  (branch ${branch}${tag:+, tag ${tag}})"
	[ -n "$(git -C "$RRF_ROOT" status --porcelain)" ] && warn "working tree has uncommitted changes"
	info "targets: $(list_target_names | paste -sd' ' -)"

	section "Summary"
	if [ $problems -eq 0 ]; then ok "Everything needed to build is in place."; return 0; fi
	warn "${problems} area(s) need attention — 'bootstrap' fixes toolchains and dependencies; Eclipse and .NET you install yourself."
	return 1
}

cmd_bootstrap() {
	local do_sync="no" with_wifi_fw="no" with_eclipse="no" arg
	for arg in "$@"; do
		case "$arg" in
			--sync) do_sync="yes" ;;
			--with-wifi-fw) with_wifi_fw="yes" ;;
			--with-eclipse) with_eclipse="yes" ;;
			*) die "bootstrap: unknown option '${arg}'" ;;
		esac
	done

	section "Bootstrapping ${WS}"
	[ -n "$HOST" ] || die "Toolchains are pinned for ${SUPPORTED_HOSTS} only, not ${HOST_OS} ${HOST_ARCH}."
	mkdir -p "$WS" "$DEPS_DIR" "$TOOLS_DIR" "$BIN_DIR"
	setup_toolchains "$with_wifi_fw" "$with_eclipse"
	setup_deps "$do_sync" "$with_wifi_fw"
	setup_crcappender
	section "Done"
	ok "Workspace ready — next: build.sh build"
}

cmd_build() {
	resolve_targets "$@"
	local -a cfgs=("${RESOLVED_TARGETS[@]}")
	section "Building ${cfgs[*]}"
	run_eclipse -build "${cfgs[@]}"
	section "Artifacts"
	report_artifacts "${cfgs[@]}" || die "The build reported success but an expected artifact is missing — check the Eclipse output above."
}

cmd_rebuild() {
	resolve_targets "$@"
	local -a cfgs=("${RESOLVED_TARGETS[@]}")
	section "Clean rebuild of ${cfgs[*]}"
	[ -d "$ECLIPSE_DATA" ] && { info "Removing Eclipse workspace metadata…"; rm -rf "$ECLIPSE_DATA"; }
	run_eclipse -cleanBuild "${cfgs[@]}"
	section "Artifacts"
	report_artifacts "${cfgs[@]}" || die "The build reported success but an expected artifact is missing — check the Eclipse output above."
}

# A release build is the one whose output is meant to be shipped, so it refuses
# anything that would make the binary unattributable to this commit.
cmd_release_build() {
	local -a cfgs=()
	if [ "$#" -eq 0 ]; then
		local name
		while read -r name; do cfgs+=("$name"); done < <(list_target_names)
	else
		resolve_targets "$@"
		cfgs=("${RESOLVED_TARGETS[@]}")
	fi

	section "Release build of ${cfgs[*]}"

	local ver tag epoch gcc
	ver="$(current_version)"
	tag="$(git -C "$RRF_ROOT" describe --tags --exact-match HEAD 2>/dev/null || printf '')"

	if [ -n "$(git -C "$RRF_ROOT" status --porcelain)" ]; then
		[ "${RRF_ALLOW_DIRTY:-0}" = "1" ] || die "Working tree is dirty — a release build must come from a committed state (set RRF_ALLOW_DIRTY=1 to override)."
		warn "Working tree is dirty and RRF_ALLOW_DIRTY=1 — the result is not reproducible"
	fi

	if [ -n "$tag" ]; then
		"${SCRIPT_DIR}/check-version.sh" "$tag" || die "Version.h does not match tag ${tag}"
	else
		warn "HEAD is not tagged — building ${ver} from $(git -C "$RRF_ROOT" rev-parse --short HEAD)"
	fi

	verify_dep_pins || die "Dependencies are off their pins — run 'build.sh bootstrap --sync'."

	gcc="$(arm_gcc)" || die "ARM toolchain missing."
	[ "$gcc" = "${ARM_GCC_DIR}/bin/arm-none-eabi-gcc" ] || die "Release builds must use the pinned toolchain in ${ARM_GCC_DIR}, not ${gcc}."
	[ "$("$gcc" -dumpversion)" = "$ARM_GCC_VERSION" ] || die "Release builds require ARM GCC ${ARM_GCC_VERSION}."

	# Pin __DATE__/__TIME__ to the commit, so the same source always produces the
	# same bytes and a released binary can be checked against its tag.
	epoch="$(git -C "$RRF_ROOT" log -1 --format=%ct HEAD)"
	export SOURCE_DATE_EPOCH="$epoch"
	info "version ${ver}${tag:+ (tag ${tag})}"
	# GNU date reads an epoch as -d @N, BSD date as -r N.
	info "SOURCE_DATE_EPOCH ${epoch} — $(date -u -d "@${epoch}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u -r "$epoch" '+%Y-%m-%d %H:%M:%S UTC')"

	[ -d "$ECLIPSE_DATA" ] && rm -rf "$ECLIPSE_DATA"
	run_eclipse -cleanBuild "${cfgs[@]}"

	section "Artifacts"
	report_artifacts "${cfgs[@]}" || die "The build reported success but an expected artifact is missing — check the Eclipse output above."

	# The full checksums, in a form that can be pasted into a comparison.
	local cfg file
	for cfg in "${cfgs[@]}"; do
		while read -r file; do sha_line 256 "$file"; done < <(target_artifacts "$cfg")
	done
}

# Print the files a release consists of, one path per line, so that a release
# workflow does not need a second copy of the target list. --maps prints the
# linker map files instead.
cmd_artifacts() {
	local maps="no" arg file cfg base entry
	local -a rest=() cfgs=()
	for arg in "$@"; do
		case "$arg" in
			--maps) maps="yes" ;;
			*) rest+=("$arg") ;;
		esac
	done

	if [ "${#rest[@]}" -eq 0 ]; then
		local name
		while read -r name; do cfgs+=("$name"); done < <(list_target_names)
	else
		resolve_targets "${rest[@]}"
		cfgs=("${RESOLVED_TARGETS[@]}")
	fi

	for cfg in "${cfgs[@]}"; do
		if [ "$maps" = "yes" ]; then
			entry="$(target_entry "$cfg")"
			IFS='|' read -r _ base _ _ <<< "$entry"
			file="${RRF_ROOT}/${cfg}/${base}.map"
			[ -f "$file" ] && printf '%s\n' "$file"
		else
			while read -r file; do
				[ -f "$file" ] && printf '%s\n' "$file"
			done < <(target_artifacts "$cfg")
		fi
	done
	return 0
}

cmd_clean() {
	local with_deps="no" arg
	for arg in "$@"; do
		case "$arg" in
			--deps) with_deps="yes" ;;
			*) die "clean: unknown option '${arg}'" ;;
		esac
	done

	section "Cleaning"
	local removed=0 name dir entry kind

	if [ -d "$ECLIPSE_DATA" ]; then rm -rf "$ECLIPSE_DATA"; ok "Removed Eclipse workspace metadata"; removed=$((removed + 1)); fi

	# Only the output directories named in targets.conf are removed: never a
	# search for directories that happen to contain a .bin.
	while read -r name; do
		dir="${RRF_ROOT}/${name}"
		if [ -d "$dir" ]; then rm -rf "$dir"; ok "Removed ${name}/"; removed=$((removed + 1)); fi
	done < <(list_target_names)

	if [ "$with_deps" = "yes" ]; then
		for entry in "${DEPS[@]}"; do
			IFS='|' read -r name _ _ _ kind <<< "$entry"
			dir="$(dep_dir "$name")"
			[ -d "${dir}/.git" ] || continue
			git -C "$dir" clean -xdfq
			ok "Cleaned build output in ${name}"
			removed=$((removed + 1))
		done
	fi

	[ $removed -eq 0 ] && info "Nothing to clean."
	ok "Clean complete"
}

cmd_targets() {
	local entry name base exts desc
	section "Configured targets"
	for entry in "${TARGETS[@]}"; do
		IFS='|' read -r name base exts desc <<< "$entry"
		printf '  %s%-20s%s %-28s [%s]  %s\n' "$C_BOLD" "$name" "$C_RESET" "${base}" "$exts" "$desc"
	done
	info "default: ${DEFAULT_TARGET}"
}

cmd_help() {
	cat <<EOF
${C_BOLD}build.sh${C_RESET} — build manager for the Vision Miner RepRapFirmware line

${C_BOLD}Usage:${C_RESET} Tools/vm-build/build.sh <command> [args]

${C_BOLD}Commands:${C_RESET}
  ${C_GREEN}doctor${C_RESET}                    Check the environment and report what is missing
  ${C_GREEN}bootstrap${C_RESET} [--sync]        Fetch toolchains + dependencies, install CrcAppender
            [--with-wifi-fw]  also fetch the ESP8266 sources and Xtensa toolchain
            [--with-eclipse]  install the pinned Eclipse even if one is present
  ${C_GREEN}build${C_RESET} [target…]           Incremental build            (default: ${DEFAULT_TARGET})
  ${C_GREEN}rebuild${C_RESET} [target…]         Clean build from a fresh Eclipse workspace
  ${C_GREEN}release-build${C_RESET} [target…]   Reproducible build of the current commit (all targets by default)
  ${C_GREEN}clean${C_RESET} [--deps]            Remove build outputs and Eclipse metadata
  ${C_GREEN}targets${C_RESET}                   List the configured targets
  ${C_GREEN}artifacts${C_RESET} [--maps] [t…]   Print the built release files, one path per line
  ${C_GREEN}help${C_RESET}                      Show this message

${C_BOLD}Options:${C_RESET}
  -v, --verbose             Show the full Eclipse and compiler output

${C_BOLD}Environment:${C_RESET}
  RRF_WS            Workspace directory (default: ${WS})
  RRF_ALLOW_DIRTY   Allow a release build from a dirty tree (not reproducible)
  V=1               Same as --verbose
  NO_COLOR          Plain output

${C_DIM}Every build writes its full log to ${BUILD_LOG}${C_RESET}

${C_DIM}Pins live in Tools/vm-build/repos.conf, targets in targets.conf.
Releasing: edit src/Version.h, commit, tag — see Tools/vm-build/README.md.${C_RESET}
EOF
}

main() {
	# --verbose is accepted anywhere, so it never has to be typed before the
	# command name and never reaches the target-name parser.
	local -a rest=()
	local a
	for a in "$@"; do
		case "$a" in
			-v|--verbose) VERBOSE="yes" ;;
			*) rest+=("$a") ;;
		esac
	done
	if [ "${#rest[@]}" -gt 0 ]; then set -- "${rest[@]}"; else set --; fi

	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
		doctor|check)          cmd_doctor "$@" ;;
		bootstrap|setup)       cmd_bootstrap "$@" ;;
		build)                 cmd_build "$@" ;;
		rebuild)               cmd_rebuild "$@" ;;
		release-build|release) cmd_release_build "$@" ;;
		clean)                 cmd_clean "$@" ;;
		targets)               cmd_targets "$@" ;;
		artifacts)             cmd_artifacts "$@" ;;
		help|-h|--help)        cmd_help ;;
		*) err "Unknown command: ${cmd}"; echo; cmd_help; exit 2 ;;
	esac
}

main "$@"
