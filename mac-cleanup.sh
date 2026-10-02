#!/usr/bin/env bash

SCRIPT_VERSION="3.0-developer"

# Deliberately avoid `set -e`: independent cleanup actions should continue after
# a failure so the final report can show every result.
set -o pipefail

MODE='interactive'
dry_run=false
verbose=false
update=false
SKIP_CODES=()
ONLY_CODES=()

ACTION_CODES=(
	trash-user cache-user-library
	cache-system-library cache-global-library
	logs-system-asl logs-diagnostic-reports logs-creative-cloud logs-adobe-system logs-adobegc
	logs-mail logs-simulator logs-jetbrains
	cache-adobe-media cache-chrome
	ios-ipa-archives ios-device-backups
	xcode-derived-data xcode-archives xcode-device-logs
	simulator-delete-unavailable simulator-erase-all
	cache-gradle cache-android cache-composer cache-npm cache-pnpm cache-corepack cache-uv
	cache-pip cache-cocoapods cache-go-build cache-go-modules cache-yarn
	cache-poetry cache-pyenv rubygems-cleanup
	homebrew-cleanup homebrew-cache homebrew-repair homebrew-update homebrew-upgrade
	cache-dropbox cache-google-drive cache-steam steam-downloads
	logs-steam cache-minecraft logs-minecraft cache-lunar logs-lunar
	logs-cacher logs-kite logs-wget java-heap-dumps
	cache-teams teams-reset docker-prune
	wallpapers-aerials
)

RUN_LOG=''
KEEP_LOG=false
SUDO_KEEPALIVE_PID=''
SUDO_READY=false
FAILED_COUNT=0
PROTECTED_COUNT=0

# Indexed arrays keep this script compatible with macOS Bash 3.2.
REPORT_LABELS=()
REPORT_CODES=()
REPORT_RISKS=()
REPORT_DELTAS=()
REPORT_STATUSES=()

setup_colors() {
	if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != 'dumb' ]]; then
		NOFORMAT='\033[0m'
		RED='\033[0;31m'
		GREEN='\033[0;32m'
		ORANGE='\033[0;33m'
		PURPLE='\033[0;35m'
		CYAN='\033[0;36m'
		YELLOW='\033[1;33m'
	else
		NOFORMAT=''
		RED=''
		GREEN=''
		ORANGE=''
		PURPLE=''
		CYAN=''
		YELLOW=''
	fi
}

msg() {
	printf >&2 '%b\n' "${1-}"
}

die() {
	msg "${RED}Error:${NOFORMAT} $1"
	exit "${2:-1}"
}

usage() {
	cat <<EOF_USAGE
Usage: $(basename "${BASH_SOURCE[0]}") [options]

Developer-focused macOS cleanup utility.

Modes:
  (no mode flag)       Interactive: offer every action individually
  --auto               Automatic: run SAFE cache actions only
  --auto --unsafe      Automatic: run all actions, including destructive ones

Options:
  -h, --help           Print this help and exit
  -v, --verbose        Print the complete command log at the end
  -u, --update         Offer Homebrew update and upgrade actions
  --dry-run            Show selected actions without executing them
  --skip CODES         Skip comma-separated action codes
  --only CODES         Consider only comma-separated action codes (risk rules still apply)
  --no-color           Disable colored output

Risk levels:
  SAFE          Regenerable cache data
  CAUTION       Logs, Trash, broad caches, or developer environment changes
  DESTRUCTIVE   Backups, archives, application state, or stopped containers
EOF_USAGE
}

is_known_code() {
	local wanted=$1
	local code
	for code in "${ACTION_CODES[@]}"; do
		[[ "$code" == "$wanted" ]] && return 0
	done
	return 1
}

add_skip_codes() {
	local value=$1
	local code
	local old_ifs=$IFS
	[[ -n "$value" ]] || die '--skip requires at least one action code' 2
	case "$value" in
	,* | *, | *,,*) die '--skip contains an empty action code' 2 ;;
	esac

	IFS=','
	for code in $value; do
		[[ -n "$code" && "$code" != *[!a-z0-9-]* ]] || die "Invalid action code in --skip: $code" 2
		is_known_code "$code" || die "Unknown action code in --skip: $code" 2
		SKIP_CODES[${#SKIP_CODES[@]}]="$code"
	done
	IFS=$old_ifs
}

add_only_codes() {
	local value=$1
	local code
	local old_ifs=$IFS
	[[ -n "$value" ]] || die '--only requires at least one action code' 2
	case "$value" in
	,* | *, | *,,*) die '--only contains an empty action code' 2 ;;
	esac

	IFS=','
	for code in $value; do
		[[ -n "$code" && "$code" != *[!a-z0-9-]* ]] || die "Invalid action code in --only: $code" 2
		is_known_code "$code" || die "Unknown action code in --only: $code" 2
		ONLY_CODES[${#ONLY_CODES[@]}]="$code"
	done
	IFS=$old_ifs
}

action_is_included() {
	local wanted=$1
	local code
	((${#ONLY_CODES[@]} == 0)) && return 0
	for code in "${ONLY_CODES[@]}"; do
		[[ "$code" == "$wanted" ]] && return 0
	done
	return 1
}

action_is_skipped() {
	local wanted=$1
	local code
	for code in "${SKIP_CODES[@]}"; do
		[[ "$code" == "$wanted" ]] && return 0
	done
	return 1
}

parse_params() {
	local auto=false
	local unsafe=false

	while (($#)); do
		case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		-v | --verbose) verbose=true ;;
		-u | --update) update=true ;;
		--auto) auto=true ;;
		--unsafe) unsafe=true ;;
		--dry-run) dry_run=true ;;
		--skip)
			(($# >= 2)) || die '--skip requires a comma-separated code list' 2
			add_skip_codes "$2"
			shift
			;;
		--skip=*) add_skip_codes "${1#--skip=}" ;;
		--only)
			(($# >= 2)) || die '--only requires a comma-separated code list' 2
			add_only_codes "$2"
			shift
			;;
		--only=*) add_only_codes "${1#--only=}" ;;
		--no-color) NO_COLOR=1 ;;
		-*) die "Unknown option: $1" 2 ;;
		*) die "Unexpected argument: $1" 2 ;;
		esac
		shift
	done

	if [[ "$unsafe" == true && "$auto" != true ]]; then
		die '--unsafe requires --auto' 2
	fi

	if [[ "$unsafe" == true ]]; then
		MODE='unsafe'
	elif [[ "$auto" == true ]]; then
		MODE='auto'
	fi
}

cleanup_on_exit() {
	local status=$?
	trap - EXIT INT TERM

	if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
		kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
		wait "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
	fi

	if [[ -n "$RUN_LOG" && -f "$RUN_LOG" && "$KEEP_LOG" != true ]]; then
		rm -f -- "$RUN_LOG"
	fi

	exit "$status"
}

on_interrupt() {
	msg ''
	msg "${ORANGE}Interrupted; stopping before the next cleanup action.${NOFORMAT}"
	exit 130
}

on_terminate() {
	msg ''
	msg "${ORANGE}Terminated; stopping before the next cleanup action.${NOFORMAT}"
	exit 143
}

trap cleanup_on_exit EXIT
trap on_interrupt INT
trap on_terminate TERM

validate_environment() {
	[[ "$(uname -s)" == 'Darwin' ]] || die 'This script supports macOS only.'
	((EUID != 0)) || die 'Run this script as your login user, not with sudo. Individual Unix-owned actions elevate themselves when required.'
	[[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != '/' && -d "$HOME" ]] || die 'HOME must be an existing absolute user directory.'
}

create_run_log() {
	local temp_root=${TMPDIR:-/tmp}
	RUN_LOG=$(mktemp "${temp_root%/}/mac-cleanup.XXXXXX") || die 'Could not create the command log.'
	chmod 600 "$RUN_LOG" || die 'Could not secure the command log.'
}

ensure_sudo() {
	if [[ "$SUDO_READY" != true ]] || ! sudo -n true >/dev/null 2>&1; then
		printf >/dev/tty '\nAdministrator access is required for this system-owned target.\n'
		if ! sudo -v; then
			return 69
		fi
		SUDO_READY=true
	fi

	if [[ -z "$SUDO_KEEPALIVE_PID" ]] || ! kill -0 "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1; then
		(
			while sudo -n true >/dev/null 2>&1; do
				sleep 60
			done
		) &
		SUDO_KEEPALIVE_PID=$!
	fi
}

available_kib() {
	local value
	value=$(df -kP / 2>/dev/null | awk 'END {print $4}') || return 1
	case "$value" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$value"
}

human_kib() {
	local kib=${1:-0}
	local sign=''

	if ((kib < 0)); then
		sign='-'
		kib=$((-kib))
	fi

	awk -v kib="$kib" -v sign="$sign" 'BEGIN {
		split("KiB MiB GiB TiB PiB", units, " ")
		value = kib
		unit = 1
		while (value >= 1024 && unit < 5) {
			value /= 1024
			unit++
		}
		if (unit == 1) printf "%s%.0f %s", sign, value, units[unit]
		else printf "%s%.2f %s", sign, value, units[unit]
	}'
}

record_result() {
	local code=$1
	local label=$2
	local risk=$3
	local delta=$4
	local status=$5
	local index=${#REPORT_LABELS[@]}

	REPORT_CODES[index]="$code"
	REPORT_LABELS[index]="$label"
	REPORT_RISKS[index]="$risk"
	REPORT_DELTAS[index]="$delta"
	REPORT_STATUSES[index]="$status"
}

risk_color() {
	case "$1" in
	SAFE) printf '%b' "$GREEN" ;;
	CAUTION) printf '%b' "$YELLOW" ;;
	DESTRUCTIVE) printf '%b' "$RED" ;;
	esac
}

risk_label() {
	case "$1" in
	SAFE) printf 'safe' ;;
	CAUTION) printf 'caution' ;;
	DESTRUCTIVE) printf 'destructive' ;;
	esac
}

confirm_action() {
	local code=$1
	local risk=$2
	local label=$3
	local target=$4
	local impact=$5
	local answer
	local color
	color=$(risk_color "$risk")

	msg ''
	msg "${color}[$(risk_label "$risk")] [${code}] ${label}${NOFORMAT}"
	msg "    target: $target"
	msg "    impact: $impact"
	printf >&2 '    Continue? [y/N] '
	IFS= read -r answer </dev/tty || answer=''

	case "$answer" in
	y | Y | yes | YES | Yes) return 0 ;;
	*) return 1 ;;
	esac
}

action_is_selected() {
	local risk=$1

	case "$MODE" in
	interactive | unsafe) return 0 ;;
	auto) [[ "$risk" == 'SAFE' ]] ;;
	esac
}

run_action() {
	local code=$1
	local risk=$2
	local label=$3
	local target=$4
	local impact=$5
	shift 5

	local before=0
	local after=0
	local delta=0
	local status=0

	# Omitted actions are not offered, executed, or included in the report.
	action_is_included "$code" || return 0

	if action_is_skipped "$code"; then
		msg "${YELLOW}[$(risk_label "$risk")] [${code}] ${label} - skipped by --skip${NOFORMAT}"
		record_result "$code" "$label" "$risk" 0 'user-skipped'
		return 0
	fi

	if ! action_is_selected "$risk"; then
		msg "${YELLOW}[$(risk_label "$risk")] [${code}] ${label} - skipped by --auto${NOFORMAT}"
		record_result "$code" "$label" "$risk" 0 'unsafe-skipped'
		return 0
	fi

	if [[ "$MODE" == 'interactive' && "$dry_run" != true ]]; then
		if ! confirm_action "$code" "$risk" "$label" "$target" "$impact"; then
			msg "    ${YELLOW}skipped${NOFORMAT}"
			record_result "$code" "$label" "$risk" 0 'declined'
			return 0
		fi
	else
		local color
		color=$(risk_color "$risk")
		msg "${color}[$(risk_label "$risk")] [${code}] ${label}${NOFORMAT}"
		msg "    target: $target"
		msg "    impact: $impact"
	fi

	if [[ "$dry_run" == true ]]; then
		record_result "$code" "$label" "$risk" 0 'dry-run'
		return 0
	fi

	before=$(available_kib) || before=0
	{
		printf '\n[%s] %s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$code" "$label"
		printf 'Target: %s\n' "$target"
	} >>"$RUN_LOG"

	if "$@" >>"$RUN_LOG" 2>&1; then
		status=0
	else
		status=$?
	fi

	after=$(available_kib) || after=$before
	delta=$((after - before))

	if ((status == 0)); then
		msg "    observed root free-space change: ${GREEN}$(human_kib "$delta")${NOFORMAT}"
		record_result "$code" "$label" "$risk" "$delta" 'ok'
	elif ((status == 77)); then
		PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
		msg "    ${YELLOW}skipped: macOS privacy protection denied access${NOFORMAT}"
		msg '    grant Full Disk Access to the terminal/host application to enable this target'
		record_result "$code" "$label" "$risk" 0 'protected-skipped'
	else
		FAILED_COUNT=$((FAILED_COUNT + 1))
		KEEP_LOG=true
		msg "    ${ORANGE}failed with exit ${status}${NOFORMAT}"
		msg "    observed root free-space change: $(human_kib "$delta") (partial cleanup may have succeeded)"
		msg '    diagnostic tail:'
		tail -n 8 "$RUN_LOG" >&2
		record_result "$code" "$label" "$risk" "$delta" "exit-$status"
	fi

	return 0
}

assert_delete_path() {
	local path=$1
	[[ -n "$path" && "$path" == /* ]] || return 64
	case "$path" in
	/ | /System | /System/* | /Library | /private | /Users | "$HOME") return 64 ;;
	esac
	return 0
}

assert_system_cleanup_path() {
	case "$1" in
	/Library/Caches | /System/Library/Caches | /private/var/log/asl | \
		/Library/Logs/DiagnosticReports | /Library/Logs/CreativeCloud | /Library/Logs/Adobe)
		return 0
		;;
	esac
	return 64
}

assert_system_cleanup_file() {
	[[ "$1" == '/Library/Logs/adobegc.log' ]]
}

directory_is_listable() {
	local directory=$1
	[[ -d "$directory" ]] || return 0
	find "$directory" -mindepth 1 -maxdepth 1 -print -quit >/dev/null 2>&1
}

remove_path() {
	local path=$1
	assert_delete_path "$path" || {
		printf >&2 'Refusing unsafe delete path: %s\n' "$path"
		return 64
	}
	if [[ -d "$path" ]] && ! directory_is_listable "$path"; then
		return 77
	fi
	rm -rf -- "$path"
}

remove_children() {
	local directory=$1
	assert_delete_path "$directory" || {
		printf >&2 'Refusing unsafe directory: %s\n' "$directory"
		return 64
	}
	[[ -d "$directory" ]] || return 0
	directory_is_listable "$directory" || return 77
	find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

remove_named_children() {
	local directory=$1
	local pattern=$2
	assert_delete_path "$directory" || return 64
	[[ -d "$directory" ]] || return 0
	directory_is_listable "$directory" || return 77
	find "$directory" -mindepth 1 -maxdepth 1 -name "$pattern" -exec rm -rf -- {} +
}

sudo_remove_children() {
	local directory=$1
	assert_system_cleanup_path "$directory" || {
		printf >&2 'Refusing unapproved system cleanup path: %s\n' "$directory"
		return 64
	}
	[[ -d "$directory" ]] || return 0
	ensure_sudo || return
	sudo find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

sudo_remove_file() {
	local path=$1
	assert_system_cleanup_file "$path" || {
		printf >&2 'Refusing unapproved system cleanup file: %s\n' "$path"
		return 64
	}
	[[ -e "$path" ]] || return 0
	ensure_sudo || return
	sudo rm -f -- "$path"
}

remove_home_matches() {
	local pattern=$1
	[[ -d "$HOME" ]] || return 0
	find "$HOME" -mindepth 1 -maxdepth 1 -name "$pattern" -exec rm -rf -- {} +
}

remove_minecraft_caches() {
	local base="$HOME/Library/Application Support/minecraft"
	remove_path "$base/webcache" || return
	remove_path "$base/webcache2" || return
	remove_path "$base/.mixin.out"
}

remove_minecraft_logs() {
	local base="$HOME/Library/Application Support/minecraft"
	remove_path "$base/logs" || return
	remove_path "$base/crash-reports" || return
	remove_path "$base/launcher_cef_log.txt" || return
	remove_named_children "$base" '*.log'
}

remove_lunar_caches() {
	local base="$HOME/.lunarclient"
	remove_path "$base/game-cache" || return
	remove_path "$base/launcher-cache"
}

remove_lunar_logs() {
	local base="$HOME/.lunarclient"
	local path
	remove_path "$base/logs" || return
	for path in "$base"/offline/*/logs "$base"/offline/files/*/logs; do
		[[ -e "$path" ]] || continue
		remove_path "$path" || return
	done
}

remove_validated_pyenv_cache() {
	local path=${PYENV_VIRTUALENV_CACHE_PATH:-}
	[[ -n "$path" && "$path" == /* ]] || return 64
	case "$path" in
	"$HOME"/.pyenv/*cache* | "$HOME"/Library/Caches/*) ;;
	*)
		printf >&2 'Refusing pyenv cache outside an approved user cache path: %s\n' "$path"
		return 64
		;;
	esac
	remove_path "$path"
}

remove_brew_cache() {
	local path
	path=$(brew --cache) || return
	case "$path" in
	"$HOME"/Library/Caches/Homebrew | /Library/Caches/Homebrew) ;;
	*)
		printf >&2 'Refusing unexpected Homebrew cache path: %s\n' "$path"
		return 64
		;;
	esac
	remove_children "$path"
}

remove_drivefs_content_cache() {
	local base="$HOME/Library/Application Support/Google/DriveFS"
	local path
	for path in "$base"/*/content_cache; do
		[[ -e "$path" ]] || continue
		remove_path "$path" || return
	done
}

remove_teams_cache() {
	local base="$HOME/Library/Application Support/Microsoft/Teams"
	local name
	for name in 'Cache' 'Application Cache' 'Code Cache' 'gpucache' 'tmp'; do
		remove_path "$base/$name" || return
	done
}

remove_steam_caches() {
	local base="$HOME/Library/Application Support/Steam"
	remove_path "$base/appcache" || return
	remove_path "$base/depotcache" || return
	remove_path "$base/steamapps/shadercache"
}

remove_steam_staging() {
	local base="$HOME/Library/Application Support/Steam/steamapps"
	remove_path "$base/download" || return
	remove_path "$base/temp"
}

reset_teams_state() {
	local base="$HOME/Library/Application Support/Microsoft/Teams"
	local name
	for name in 'IndexedDB' 'blob_storage' 'databases' 'Local Storage' 'watchdog'; do
		remove_path "$base/$name" || return
	done
	remove_named_children "$base" '*logs*.txt' || return
	remove_named_children "$base" '*watchdog*.json'
}

# --- Wallpaper and screensaver aerial videos --------------------------------
#
# macOS 26 "Tahoe" downloads aerial movies to
#   ~/Library/Application Support/com.apple.wallpaper/aerials/videos/*.mov
# with a catalog at .../aerials/manifest/entries.json. Older releases kept
# root-owned movies one directory deep under
#   /Library/Application Support/com.apple.idleassetsd/Customer/
# Both share the wallpaper selection at
#   ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist.
#
# A movie is considered unused only when its UUID is a known catalog asset and
# is not referenced, directly or through a category/subcategory shuffle
# selection, by the active configuration. Unknown movies are never touched, and
# detection refuses to run when an aerial provider is configured but no
# selection can be parsed.

WALLPAPER_INDEX_PLIST="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
AERIAL_TAHOE_VIDEOS="$HOME/Library/Application Support/com.apple.wallpaper/aerials/videos"
AERIAL_TAHOE_MANIFEST="$HOME/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"
AERIAL_LEGACY_SYSTEM_BASE='/Library/Application Support/com.apple.idleassetsd/Customer'
AERIAL_LEGACY_USER_BASE="$HOME/Library/Application Support/com.apple.idleassetsd/Customer"

AERIALS_UNUSED_PATHS=()
AERIALS_UNUSED_LABELS=()
AERIALS_UNUSED_BYTES=()
AERIALS_UNUSED_COUNT=0
AERIALS_UNUSED_KIB=0

xml_unescape() {
	local value=$1
	value=${value//&amp;/&}
	value=${value//&quot;/\"}
	value=${value//&apos;/\'}
	value=${value//&lt;/<}
	value=${value//&gt;/>}
	printf '%s' "$value"
}

# Recursively print every assetID from a wallpaper Index.plist read on stdin.
# Selection data is a binary plist embedded as <data>, so decode and recurse.
# The same key stores individual asset IDs and category/subcategory IDs.
wallpaper_asset_ids() {
	local xml
	local b64
	xml=$(plutil -convert xml1 -o - - 2>/dev/null) || return 0
	printf '%s\n' "$xml" | awk '
		/<key>assetID<\/key>/ { getline; sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>.*/, ""); print }
	'
	printf '%s\n' "$xml" | awk '
		/<data>/ { inside = 1; buf = ""; next }
		/<\/data>/ { inside = 0; gsub(/[[:space:]]/, "", buf); if (buf != "") print buf; next }
		inside { buf = buf $0 }
	' | while IFS= read -r b64; do
		printf '%s' "$b64" | base64 -D 2>/dev/null | wallpaper_asset_ids
	done
}

# Flatten an entries.json catalog into tab-separated records:
#   A<TAB>asset-id<TAB>label
#   C<TAB>category-id<TAB>asset-id
#   S<TAB>subcategory-id<TAB>asset-id
aerial_manifest_records() {
	local manifest=$1
	local xml
	[[ -f "$manifest" ]] || return 1
	xml=$(plutil -convert xml1 -o - "$manifest" 2>/dev/null) || return 1
	printf '%s\n' "$xml" | awk '
		{
			line = $0
			indent = 0
			while (substr(line, indent + 1, 1) == "\t") indent++
			body = substr(line, indent + 1)
		}
		body == "<key>assets</key>" && indent == 1 { want_assets = 1; next }
		body ~ /^<key>/ && indent == 1 { want_assets = 0; next }
		want_assets && body == "<array>" && indent == 1 { in_assets = 1; want_assets = 0; next }
		!in_assets { next }
		body == "</array>" && indent == 1 { in_assets = 0; next }
		body == "<dict>" && indent == 2 { aid = ""; label = ""; cats = ""; subs = ""; key = ""; next }
		body == "</dict>" && indent == 2 {
			if (aid != "") printf "A\t%s\t%s\n", aid, label
			n = split(cats, parts, ",")
			for (i = 1; i <= n; i++) if (parts[i] != "") printf "C\t%s\t%s\n", parts[i], aid
			n = split(subs, parts, ",")
			for (i = 1; i <= n; i++) if (parts[i] != "") printf "S\t%s\t%s\n", parts[i], aid
			next
		}
		indent == 3 && body ~ /^<key>/ { key = body; sub(/^<key>/, "", key); sub(/<\/key>$/, "", key); next }
		indent == 3 && body ~ /^<string>/ {
			value = body; sub(/^<string>/, "", value); sub(/<\/string>$/, "", value)
			if (key == "id") aid = value
			else if (key == "accessibilityLabel") label = value
			next
		}
		indent == 4 && body ~ /^<string>/ {
			value = body; sub(/^<string>/, "", value); sub(/<\/string>$/, "", value)
			if (key == "categories") cats = (cats == "" ? value : cats "," value)
			else if (key == "subcategories") subs = (subs == "" ? value : subs "," value)
			next
		}
	'
}

list_has_exact() {
	local list=$1
	local item=$2
	[[ -n "$item" ]] || return 1
	printf '%s\n' "$list" | grep -Fxq -- "$item"
}

aerial_label_for() {
	local records=$1
	local id=$2
	printf '%s\n' "$records" | awk -F'\t' -v id="$id" '$1 == "A" && $2 == id { print $3; exit }'
}

# Expand active selection IDs to the asset IDs they protect. An ID that names
# an asset, a category, or a subcategory is resolved; anything else is ignored.
aerial_expand_protected() {
	local records=$1
	local active=$2
	local id
	local matches
	for id in $active; do
		if printf '%s\n' "$records" | awk -F'\t' -v id="$id" '$1 == "A" && $2 == id { found = 1 } END { exit !found }'; then
			printf '%s\n' "$id"
			continue
		fi
		matches=$(printf '%s\n' "$records" | awk -F'\t' -v id="$id" '$1 == "C" && $2 == id { print $3 }')
		if [[ -z "$matches" ]]; then
			matches=$(printf '%s\n' "$records" | awk -F'\t' -v id="$id" '$1 == "S" && $2 == id { print $3 }')
		fi
		[[ -n "$matches" ]] && printf '%s\n' "$matches"
	done
}

# Asset IDs currently open by the wallpaper or screensaver renderer, used as an
# extra guard in addition to the parsed configuration.
aerial_playing_ids() {
	local proc
	local pid
	local path
	for proc in WallpaperAerialsExtension ScreenSaverEngine; do
		while IFS= read -r pid; do
			while IFS= read -r path; do
				[[ -n "$path" ]] || continue
				path=${path##*/}
				printf '%s\n' "${path%.mov}"
			done < <(lsof -Fn -p "$pid" 2>/dev/null | sed -n 's/^n\(.*\.mov\)$/\1/p')
		done < <(pgrep -x "$proc" 2>/dev/null)
	done
}

aerial_stores() {
	printf '%s\n' "tahoe|$AERIAL_TAHOE_MANIFEST|$AERIAL_TAHOE_VIDEOS"
	printf '%s\n' "legacy|$AERIAL_LEGACY_SYSTEM_BASE/entries.json|$AERIAL_LEGACY_SYSTEM_BASE"
	printf '%s\n' "legacy|$AERIAL_LEGACY_USER_BASE/entries.json|$AERIAL_LEGACY_USER_BASE"
}

aerials_store_available() {
	[[ -d "$AERIAL_TAHOE_VIDEOS" || -d "$AERIAL_LEGACY_SYSTEM_BASE" || -d "$AERIAL_LEGACY_USER_BASE" ]]
}

aerials_path_is_approved() {
	case "$1" in
	"$AERIAL_TAHOE_VIDEOS"/*.mov) return 0 ;;
	"$AERIAL_LEGACY_SYSTEM_BASE"/*.mov | "$AERIAL_LEGACY_SYSTEM_BASE"/*/*.mov) return 0 ;;
	"$AERIAL_LEGACY_USER_BASE"/*.mov | "$AERIAL_LEGACY_USER_BASE"/*/*.mov) return 0 ;;
	esac
	return 1
}

aerials_consider_path() {
	local path=$1
	local records=$2
	local known=$3
	local protected=$4
	local uuid
	local size
	uuid=${path##*/}
	uuid=${uuid%.mov}
	list_has_exact "$known" "$uuid" || return 0
	list_has_exact "$protected" "$uuid" && return 0
	size=$(stat -f%z "$path" 2>/dev/null) || size=0
	case "$size" in
	'' | *[!0-9]*) size=0 ;;
	esac
	AERIALS_UNUSED_PATHS[${#AERIALS_UNUSED_PATHS[@]}]="$path"
	AERIALS_UNUSED_LABELS[${#AERIALS_UNUSED_LABELS[@]}]="$(aerial_label_for "$records" "$uuid")"
	AERIALS_UNUSED_BYTES[${#AERIALS_UNUSED_BYTES[@]}]="$size"
}

# Populate AERIALS_UNUSED_* with downloaded movies that no configuration
# references. Returns non-zero when no safe determination can be made.
aerials_detect() {
	local config_ids
	local playing_ids
	local provider_present=false
	local mode
	local manifest
	local root
	local records
	local valid_ids=''
	local known=''
	local protected=''
	local path
	local id
	local total=0
	local i

	AERIALS_UNUSED_PATHS=()
	AERIALS_UNUSED_LABELS=()
	AERIALS_UNUSED_BYTES=()
	AERIALS_UNUSED_COUNT=0
	AERIALS_UNUSED_KIB=0

	[[ -f "$WALLPAPER_INDEX_PLIST" ]] || return 1
	command -v plutil >/dev/null 2>&1 || return 1

	if plutil -convert xml1 -o - "$WALLPAPER_INDEX_PLIST" 2>/dev/null |
		grep -q 'com.apple.wallpaper.choice.aerials'; then
		provider_present=true
	fi

	config_ids=$(wallpaper_asset_ids <"$WALLPAPER_INDEX_PLIST") || return 1
	if [[ -z "$config_ids" && "$provider_present" == true ]]; then
		return 1
	fi
	playing_ids=$(aerial_playing_ids)

	while IFS='|' read -r mode manifest root; do
		[[ -n "$manifest" && -f "$manifest" ]] || continue
		records=$(aerial_manifest_records "$manifest") || continue
		[[ -n "$records" ]] || continue
		valid_ids=$(printf '%s\n%s\n' "$valid_ids" "$(printf '%s\n' "$records" | awk -F'\t' '$1 != "" { print $2 }')")
		known=$(printf '%s\n%s\n' "$known" "$(printf '%s\n' "$records" | awk -F'\t' '$1 == "A" { print $2 }')")
		protected=$(printf '%s\n%s\n' "$protected" "$(aerial_expand_protected "$records" "$config_ids")")
		case "$mode" in
		tahoe)
			for path in "$root"/*.mov; do
				[[ -f "$path" ]] || continue
				aerials_consider_path "$path" "$records" "$known" "$protected"
			done
			;;
		legacy)
			while IFS= read -r path; do
				[[ -n "$path" ]] || continue
				aerials_consider_path "$path" "$records" "$known" "$protected"
			done < <(find "$root" -maxdepth 2 -type f -name '*.mov' 2>/dev/null)
			;;
		esac
	done < <(aerial_stores)

	# A configured selection that resolves to nothing means the catalog could
	# not be interpreted reliably; refuse to guess which movies are unused.
	for id in $config_ids; do
		list_has_exact "$valid_ids" "$id" || return 1
	done

	[[ -n "$playing_ids" ]] && protected=$(printf '%s\n%s\n' "$protected" "$playing_ids")

	AERIALS_UNUSED_COUNT=${#AERIALS_UNUSED_PATHS[@]}
	for ((i = 0; i < AERIALS_UNUSED_COUNT; i++)); do
		total=$((total + AERIALS_UNUSED_BYTES[i]))
	done
	AERIALS_UNUSED_KIB=$((total / 1024))
	return 0
}

aerials_print_unused() {
	local i
	local label
	msg ''
	msg "${CYAN}Wallpaper aerials - unused downloads:${NOFORMAT}"
	for ((i = 0; i < AERIALS_UNUSED_COUNT; i++)); do
		label=$(xml_unescape "${AERIALS_UNUSED_LABELS[i]}")
		msg "    ${label:-unknown} (${AERIALS_UNUSED_PATHS[i]##*/}) $(human_kib $((AERIALS_UNUSED_BYTES[i] / 1024)))"
	done
}

cleanup_unused_aerial_videos() {
	local i
	local path
	aerials_detect || {
		printf 'Aerial configuration could not be parsed safely; nothing removed.\n'
		return 0
	}
	for ((i = 0; i < ${#AERIALS_UNUSED_PATHS[@]}; i++)); do
		path=${AERIALS_UNUSED_PATHS[i]}
		aerials_path_is_approved "$path" || {
			printf 'Refusing unapproved aerial path: %s\n' "$path"
			return 1
		}
		if [[ -w "$path" || -w "$(dirname "$path")" ]]; then
			rm -f -- "$path" || return
		else
			ensure_sudo || return
			sudo rm -f -- "$path" || return
		fi
		printf 'Removed %s (%s)\n' "$path" "$(human_kib $((AERIALS_UNUSED_BYTES[i] / 1024)))"
	done
}

erase_all_simulators() {
	/usr/bin/osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
	xcrun simctl shutdown all >/dev/null 2>&1 || true
	xcrun simctl erase all
}

print_mode_banner() {
	local skipped
	local included
	msg "${GREEN}mac-cleanup ${SCRIPT_VERSION}${NOFORMAT}"
	case "$MODE" in
	interactive)
		msg 'Mode: interactive - every applicable action requires approval; Enter means No.'
		;;
	auto)
		msg 'Mode: automatic safe cleanup - only allowlisted, regenerable caches will run.'
		;;
	unsafe)
		msg "${RED}Mode: UNSAFE AUTOMATIC - every applicable action will run without prompting.${NOFORMAT}"
		msg "${RED}This can permanently remove backups, Xcode archives/dSYMs, simulator data,"
		msg "stopped Docker containers, offline cloud cache, and application state.${NOFORMAT}"
		;;
	esac
	if ((${#SKIP_CODES[@]} > 0)); then
		skipped=$(IFS=,; printf '%s' "${SKIP_CODES[*]}")
		msg "Skipped action codes: $skipped"
	fi
	if ((${#ONLY_CODES[@]} > 0)); then
		included=$(IFS=,; printf '%s' "${ONLY_CODES[*]}")
		msg "Only action codes: $included"
	fi
	[[ "$dry_run" == true ]] && msg "${CYAN}Dry run: no commands will be executed.${NOFORMAT}"
}

print_report() {
	local i
	local delta
	msg ''
	msg "${PURPLE}Cleanup report${NOFORMAT}"
	printf >&2 '%-29s %-32s %-11s %12s %-16s\n' 'Code' 'Action' 'Risk' 'Net' 'Status'
	printf >&2 '%-29s %-32s %-11s %12s %-16s\n' '-----------------------------' '--------------------------------' '-----------' '------------' '----------------'
	for ((i = 0; i < ${#REPORT_LABELS[@]}; i++)); do
		if [[ "${REPORT_STATUSES[i]}" == 'ok' || "${REPORT_STATUSES[i]}" == exit-* ]]; then
			delta=$(human_kib "${REPORT_DELTAS[i]}")
		else
			delta='-'
		fi
		printf >&2 '%-29.29s %-32.32s %-11s %12s %-16s\n' \
			"${REPORT_CODES[i]}" "${REPORT_LABELS[i]}" "$(risk_label "${REPORT_RISKS[i]}")" "$delta" "${REPORT_STATUSES[i]}"
	done
}

print_reclaimed_summary() {
	local before=$1
	local after=$2
	local delta

	if [[ "$dry_run" == true ]]; then
		msg 'Total reclaimed space: not measured (dry run)'
		return 0
	fi

	if [[ -z "$before" || -z "$after" ]]; then
		msg 'Total reclaimed space: unavailable'
		return 0
	fi

	delta=$((after - before))
	msg "Total reclaimed space: $(human_kib "$delta")"
}

run_cleanups() {
	# Broad/user-managed data.
	run_action trash-user CAUTION 'Trash: current user' "$HOME/.Trash/*" \
		'Removes recoverable files currently placed in Trash.' \
		remove_children "$HOME/.Trash"
	run_action cache-user-library CAUTION 'Cache: all user applications' "$HOME/Library/Caches/*" \
		'Removes all user application caches; close applications first. Some protected entries may remain.' \
		remove_children "$HOME/Library/Caches"

	# System-owned caches and logs. These are destructive, require targeted sudo,
	# and may be blocked by System Integrity Protection on modern macOS.
	run_action cache-global-library DESTRUCTIVE 'Cache: global Library' '/Library/Caches/*' \
		'Removes machine-wide application and service caches; running services may be disrupted.' \
		sudo_remove_children '/Library/Caches'
	run_action cache-system-library DESTRUCTIVE 'Cache: System Library' '/System/Library/Caches/*' \
		'Removes protected macOS caches. SIP normally blocks this and failures are expected.' \
		sudo_remove_children '/System/Library/Caches'
	run_action logs-system-asl DESTRUCTIVE 'Logs: system ASL' '/private/var/log/asl/*' \
		'Removes legacy system logs and diagnostic history managed by macOS.' \
		sudo_remove_children '/private/var/log/asl'
	run_action logs-diagnostic-reports DESTRUCTIVE 'Logs: system diagnostic reports' '/Library/Logs/DiagnosticReports/*' \
		'Removes machine-wide crash and diagnostic reports used for troubleshooting.' \
		sudo_remove_children '/Library/Logs/DiagnosticReports'
	run_action logs-creative-cloud CAUTION 'Logs: Creative Cloud' '/Library/Logs/CreativeCloud/*' \
		'Removes machine-wide Creative Cloud logs.' sudo_remove_children '/Library/Logs/CreativeCloud'
	run_action logs-adobe-system CAUTION 'Logs: Adobe system' '/Library/Logs/Adobe/*' \
		'Removes machine-wide Adobe logs.' sudo_remove_children '/Library/Logs/Adobe'
	run_action logs-adobegc CAUTION 'Logs: Adobe GC' '/Library/Logs/adobegc.log' \
		'Removes the machine-wide Adobe GC diagnostic log.' sudo_remove_file '/Library/Logs/adobegc.log'

	# Logs and diagnostics are deliberately excluded from safe automatic mode.
	run_action logs-mail CAUTION 'Logs: Apple Mail' "$HOME/Library/Containers/com.apple.mail/Data/Library/Logs/Mail/*" \
		'Removes Mail diagnostic logs.' \
		remove_children "$HOME/Library/Containers/com.apple.mail/Data/Library/Logs/Mail"
	run_action logs-simulator CAUTION 'Logs: CoreSimulator' "$HOME/Library/Logs/CoreSimulator/*" \
		'Removes simulator diagnostics that may be useful for debugging.' \
		remove_children "$HOME/Library/Logs/CoreSimulator"
	[[ -d "$HOME/Library/Logs/JetBrains" ]] && run_action logs-jetbrains CAUTION 'Logs: JetBrains' "$HOME/Library/Logs/JetBrains/*" \
		'Removes IDE diagnostic logs.' remove_children "$HOME/Library/Logs/JetBrains"

	# Regenerable application caches.
	[[ -d "$HOME/Library/Application Support/Adobe/Common/Media Cache Files" ]] && run_action cache-adobe-media SAFE 'Cache: Adobe media' "$HOME/Library/Application Support/Adobe/Common/Media Cache Files/*" \
		'Removes regenerable Adobe media cache; close Adobe applications first.' remove_children "$HOME/Library/Application Support/Adobe/Common/Media Cache Files"
	[[ -d "$HOME/Library/Application Support/Google/Chrome/Default/Application Cache" ]] && run_action cache-chrome SAFE 'Cache: Chrome application cache' "$HOME/Library/Application Support/Google/Chrome/Default/Application Cache/*" \
		'Removes regenerable Chrome application cache; close Chrome first.' remove_children "$HOME/Library/Application Support/Google/Chrome/Default/Application Cache"

	# Apple developer data.
	run_action ios-ipa-archives DESTRUCTIVE 'iOS: archived applications' "$HOME/Music/iTunes/iTunes Media/Mobile Applications/*" \
		'Removes every archived IPA; removed App Store releases may be impossible to recover.' \
		remove_children "$HOME/Music/iTunes/iTunes Media/Mobile Applications"
	run_action ios-device-backups DESTRUCTIVE 'iOS: device backups' "$HOME/Library/Application Support/MobileSync/Backup/*" \
		'Permanently removes local iPhone and iPad backups. These are user backups, not caches.' \
		remove_children "$HOME/Library/Application Support/MobileSync/Backup"
	run_action xcode-derived-data SAFE 'Xcode: DerivedData' "$HOME/Library/Developer/Xcode/DerivedData/*" \
		'Removes regenerable indexes and build products; the next build will be slower.' \
		remove_children "$HOME/Library/Developer/Xcode/DerivedData"
	run_action xcode-archives DESTRUCTIVE 'Xcode: Archives and dSYMs' "$HOME/Library/Developer/Xcode/Archives/*" \
		'Removes release archives and dSYMs needed for export and crash symbolication.' \
		remove_children "$HOME/Library/Developer/Xcode/Archives"
	run_action xcode-device-logs CAUTION 'Xcode: iOS device logs' "$HOME/Library/Developer/Xcode/iOS Device Logs/*" \
		'Removes device diagnostics that may be useful for debugging.' \
		remove_children "$HOME/Library/Developer/Xcode/iOS Device Logs"
	if command -v xcrun >/dev/null 2>&1; then
		run_action simulator-delete-unavailable CAUTION 'Simulator: delete unavailable devices' 'xcrun simctl delete unavailable' \
			'Removes unsupported simulator devices and all data stored inside them.' xcrun simctl delete unavailable
		run_action simulator-erase-all DESTRUCTIVE 'Simulator: erase all data' 'xcrun simctl erase all' \
			'Erases every simulator app, database, keychain, account, photo, and test fixture.' erase_all_simulators
	fi

	# Build-tool and language caches.
	[[ -d "$HOME/.gradle/caches" ]] && run_action cache-gradle SAFE 'Cache: Gradle' "$HOME/.gradle/caches" \
		'Removes downloaded and generated Gradle caches; stop active builds first.' remove_path "$HOME/.gradle/caches"
	[[ -d "$HOME/.android/cache" ]] && run_action cache-android SAFE 'Cache: Android tools' "$HOME/.android/cache" \
		'Removes regenerable Android tooling cache.' remove_path "$HOME/.android/cache"
	command -v composer >/dev/null 2>&1 && run_action cache-composer SAFE 'Cache: Composer' 'composer clear-cache' \
		'Removes Composer download caches; dependencies may need to be downloaded again.' composer clear-cache --no-interaction
	command -v npm >/dev/null 2>&1 && run_action cache-npm SAFE 'Cache: npm' 'npm cache clean --force' \
		'Removes npm cache; packages will be downloaded again.' npm cache clean --force
	command -v pnpm >/dev/null 2>&1 && run_action cache-pnpm SAFE 'Cache: pnpm store' 'pnpm store prune' \
		'Removes unreferenced packages from the pnpm store.' pnpm store prune
	command -v corepack >/dev/null 2>&1 && run_action cache-corepack CAUTION 'Cache: Corepack' 'corepack cache clean' \
		'Removes downloaded package-manager versions; they may be needed for offline projects.' corepack cache clean
	command -v uv >/dev/null 2>&1 && run_action cache-uv SAFE 'Cache: uv' 'uv cache clean' \
		'Removes uv package cache; packages will be downloaded again.' uv cache clean
	if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
		run_action cache-pip SAFE 'Cache: pip' 'python3 -m pip cache purge' \
			'Removes pip download and wheel caches.' python3 -m pip cache purge
	fi
	command -v pod >/dev/null 2>&1 && run_action cache-cocoapods SAFE 'Cache: CocoaPods' 'pod cache clean --all' \
		'Removes cached pod packages; dependencies may need to be downloaded again.' pod cache clean --all
	command -v go >/dev/null 2>&1 && run_action cache-go-build SAFE 'Cache: Go build' 'go clean -cache -testcache' \
		'Removes Go build and test caches without deleting the module download cache.' go clean -cache -testcache
	command -v go >/dev/null 2>&1 && run_action cache-go-modules CAUTION 'Cache: Go modules' 'go clean -modcache' \
		'Removes every downloaded Go module; unavailable versions may not be recoverable.' go clean -modcache
	command -v yarn >/dev/null 2>&1 && run_action cache-yarn CAUTION 'Cache: Yarn' 'yarn cache clean' \
		'Behavior differs by Yarn version and may remove a project-local zero-install cache.' yarn cache clean
	[[ -d "$HOME/Library/Caches/pypoetry" ]] && run_action cache-poetry SAFE 'Cache: Poetry' "$HOME/Library/Caches/pypoetry" \
		'Removes Poetry package caches; packages will be downloaded again.' remove_path "$HOME/Library/Caches/pypoetry"
	if [[ -n "${PYENV_VIRTUALENV_CACHE_PATH:-}" ]]; then
		run_action cache-pyenv CAUTION 'Cache: pyenv-virtualenv' "$PYENV_VIRTUALENV_CACHE_PATH" \
			'Removes the configured pyenv-virtualenv cache after validating that it is under an approved user cache path.' \
			remove_validated_pyenv_cache
	fi
	command -v gem >/dev/null 2>&1 && run_action rubygems-cleanup DESTRUCTIVE 'RubyGems: old installed versions' 'gem cleanup' \
		'Removes old installed gem versions and may break scripts pinned to them.' gem cleanup

	# Homebrew cleanup is separate from environment mutation.
	if command -v brew >/dev/null 2>&1; then
		run_action homebrew-cleanup SAFE 'Homebrew: cleanup' 'brew cleanup -s' \
			'Removes old downloads and outdated package artifacts managed by Homebrew.' brew cleanup -s
		run_action homebrew-cache CAUTION 'Homebrew: complete download cache' 'contents of brew --cache' \
			'Removes all files in Homebrew download cache, including current downloads.' remove_brew_cache
		run_action homebrew-repair CAUTION 'Homebrew: repair taps' 'brew tap --repair' \
			'Repairs and mutates Homebrew tap Git repositories; this is maintenance rather than cleanup.' brew tap --repair
		if [[ "$update" == true ]]; then
			run_action homebrew-update CAUTION 'Homebrew: update metadata' 'brew update' \
				'Fetches current formula and cask metadata.' brew update
			run_action homebrew-upgrade DESTRUCTIVE 'Homebrew: upgrade packages' 'brew upgrade' \
				'Changes installed developer tools and services and may introduce breaking versions.' brew upgrade
		fi
	fi

	# Cloud/application state and game clients.
	[[ -d "$HOME/Dropbox/.dropbox.cache" ]] && run_action cache-dropbox CAUTION 'Cache: Dropbox recovery cache' "$HOME/Dropbox/.dropbox.cache/*" \
		'Removes Dropbox recovery cache; verify synchronization and close Dropbox first.' remove_children "$HOME/Dropbox/.dropbox.cache"
	[[ -d "$HOME/Library/Application Support/Google/DriveFS" ]] && run_action cache-google-drive DESTRUCTIVE 'Google Drive: content cache' "$HOME/Library/Application Support/Google/DriveFS/*/content_cache" \
		'Removes offline cached content; verify all changes are synchronized and close Drive first.' remove_drivefs_content_cache

	if [[ -d "$HOME/Library/Application Support/Steam" ]]; then
		run_action cache-steam SAFE 'Steam: regenerable caches' 'Steam appcache, depotcache, shadercache' \
			'Removes regenerable metadata and shaders; close Steam first.' \
			remove_steam_caches
		run_action steam-downloads DESTRUCTIVE 'Steam: downloads and staging' 'Steam steamapps/download and steamapps/temp' \
			'Removes active or staged game downloads and updates.' \
			remove_steam_staging
		run_action logs-steam CAUTION 'Logs: Steam' "$HOME/Library/Application Support/Steam/logs" \
			'Removes Steam diagnostic logs; close Steam first.' \
			remove_path "$HOME/Library/Application Support/Steam/logs"
	fi

	if [[ -d "$HOME/Library/Application Support/minecraft" ]]; then
		run_action cache-minecraft SAFE 'Cache: Minecraft' 'Minecraft webcache, webcache2, and .mixin.out' \
			'Removes regenerable Minecraft launcher and mixin caches; close Minecraft first.' remove_minecraft_caches
		run_action logs-minecraft CAUTION 'Logs: Minecraft' 'Minecraft logs, crash reports, and launcher logs' \
			'Removes Minecraft diagnostics and crash reports.' remove_minecraft_logs
	fi

	if [[ -d "$HOME/.lunarclient" ]]; then
		run_action cache-lunar SAFE 'Cache: Lunar Client' 'Lunar Client game-cache and launcher-cache' \
			'Removes regenerable Lunar Client caches; close Lunar Client first.' remove_lunar_caches
		run_action logs-lunar CAUTION 'Logs: Lunar Client' 'Lunar Client logs and offline profile logs' \
			'Removes Lunar Client diagnostic logs.' remove_lunar_logs
	fi

	[[ -d "$HOME/.cacher/logs" ]] && run_action logs-cacher CAUTION 'Logs: Cacher' "$HOME/.cacher/logs" \
		'Removes Cacher diagnostic logs.' remove_path "$HOME/.cacher/logs"
	[[ -d "$HOME/.kite/logs" ]] && run_action logs-kite CAUTION 'Logs: Kite' "$HOME/.kite/logs" \
		'Removes logs from the discontinued KiteXcode tool.' remove_path "$HOME/.kite/logs"
	[[ -f "$HOME/wget-log" ]] && run_action logs-wget CAUTION 'Logs: wget' "$HOME/wget-log" \
		'Removes wget output log; wget HSTS security state is retained.' remove_path "$HOME/wget-log"
	run_action java-heap-dumps DESTRUCTIVE 'Java: heap dumps' "$HOME/*.hprof" \
		'Removes Java heap dumps that may contain valuable out-of-memory diagnostics.' remove_home_matches '*.hprof'

	if [[ -d "$HOME/Library/Application Support/Microsoft/Teams" ]]; then
		run_action cache-teams CAUTION 'Teams: regenerable caches' 'Teams Cache, Application Cache, Code Cache, GPU cache, tmp' \
			'Removes regenerable Teams caches; quit Teams first.' remove_teams_cache
		run_action teams-reset DESTRUCTIVE 'Teams: local application state' 'Teams IndexedDB, databases, Local Storage, blob storage, watchdog' \
			'Resets local Teams state and may remove sessions, preferences, drafts, or offline data.' reset_teams_state
	fi

	# macOS wallpaper and screensaver aerial movies.
	if action_is_included wallpapers-aerials && aerials_store_available && [[ -f "$WALLPAPER_INDEX_PLIST" ]]; then
		if aerials_detect; then
			if ((AERIALS_UNUSED_COUNT > 0)); then
				if [[ "$MODE" != 'auto' ]] && ! action_is_skipped wallpapers-aerials; then
					aerials_print_unused
				fi
				run_action wallpapers-aerials CAUTION 'Wallpapers: unused aerial videos' \
					"${AERIALS_UNUSED_COUNT} unused download(s), $(human_kib "$AERIALS_UNUSED_KIB")" \
					'Removes downloaded aerial wallpaper and screensaver movies that the current configuration does not reference, including category and subcategory shuffle selections. macOS re-downloads a movie when it is selected again.' \
					cleanup_unused_aerial_videos
			fi
		else
			msg "${YELLOW}Wallpapers: aerial cleanup skipped; the configuration could not be parsed safely.${NOFORMAT}"
		fi
	fi

	if command -v docker >/dev/null 2>&1; then
		run_action docker-prune DESTRUCTIVE 'Docker: full system prune' 'docker system prune -af' \
			'Removes stopped containers and their writable data, unused networks, images, and build cache. Volumes are retained.' \
			docker system prune -af
	fi
}

main() {
	local start_kib=''
	local end_kib=''

	parse_params "$@"
	setup_colors
	validate_environment
	create_run_log
	print_mode_banner
	start_kib=$(available_kib) || start_kib=''
	run_cleanups
	end_kib=$(available_kib) || end_kib=''
	print_report
	print_reclaimed_summary "$start_kib" "$end_kib"

	if [[ "$verbose" == true && -s "$RUN_LOG" ]]; then
		msg ''
		msg "${CYAN}Complete command log${NOFORMAT}"
		cat "$RUN_LOG" >&2
	fi

	if ((PROTECTED_COUNT > 0)); then
		msg ''
		msg "${YELLOW}${PROTECTED_COUNT} action(s) were skipped by macOS privacy protection.${NOFORMAT}"
		msg 'This is not a Unix ownership problem, so sudo may not fix it.'
		msg 'To enable those targets: System Settings → Privacy & Security → Full Disk Access'
		msg 'and enable the application hosting this shell (Terminal, iTerm, or OpenCode), then restart it.'
	fi

	if ((FAILED_COUNT > 0)); then
		KEEP_LOG=true
		msg ''
		msg "${ORANGE}Completed with ${FAILED_COUNT} failed action(s).${NOFORMAT}"
		msg "Command log retained at: $RUN_LOG"
		return 1
	fi

	msg ''
	if [[ "$dry_run" == true ]]; then
		msg "${GREEN}Dry run complete; nothing was removed.${NOFORMAT}"
	else
		msg "${GREEN}Cleanup complete.${NOFORMAT}"
	fi
	msg 'Disk changes are observed via df and can fluctuate because of APFS and background activity.'
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
