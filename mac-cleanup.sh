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

ACTION_CODES=(
	trash-user logs-mail logs-simulator logs-jetbrains
	cache-adobe-media cache-chrome
	ios-ipa-archives ios-device-backups
	xcode-derived-data xcode-archives xcode-device-logs
	simulator-delete-unavailable simulator-erase-all
	cache-gradle cache-android cache-composer cache-npm cache-pnpm cache-uv
	cache-pip cache-cocoapods cache-go-build cache-yarn rubygems-cleanup
	homebrew-cleanup homebrew-update homebrew-upgrade
	cache-dropbox cache-google-drive cache-steam steam-downloads
	cache-teams teams-reset docker-prune
)

RUN_LOG=''
KEEP_LOG=false
SUDO_KEEPALIVE_PID=''
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

erase_all_simulators() {
	/usr/bin/osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
	xcrun simctl shutdown all >/dev/null 2>&1 || true
	xcrun simctl erase all
}

print_mode_banner() {
	local skipped
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
		if [[ "${REPORT_STATUSES[i]}" == 'ok' ]]; then
			delta=$(human_kib "${REPORT_DELTAS[i]}")
		else
			delta='-'
		fi
		printf >&2 '%-29.29s %-32.32s %-11s %12s %-16s\n' \
			"${REPORT_CODES[i]}" "${REPORT_LABELS[i]}" "$(risk_label "${REPORT_RISKS[i]}")" "$delta" "${REPORT_STATUSES[i]}"
	done
}

run_cleanups() {
	# Broad/user-managed data.
	run_action trash-user CAUTION 'Trash: current user' "$HOME/.Trash/*" \
		'Removes recoverable files currently placed in Trash.' \
		remove_children "$HOME/.Trash"

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
	command -v yarn >/dev/null 2>&1 && run_action cache-yarn CAUTION 'Cache: Yarn' 'yarn cache clean' \
		'Behavior differs by Yarn version and may remove a project-local zero-install cache.' yarn cache clean
	command -v gem >/dev/null 2>&1 && run_action rubygems-cleanup DESTRUCTIVE 'RubyGems: old installed versions' 'gem cleanup' \
		'Removes old installed gem versions and may break scripts pinned to them.' gem cleanup

	# Homebrew cleanup is separate from environment mutation.
	if command -v brew >/dev/null 2>&1; then
		run_action homebrew-cleanup SAFE 'Homebrew: cleanup' 'brew cleanup -s' \
			'Removes old downloads and outdated package artifacts managed by Homebrew.' brew cleanup -s
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
	fi

	if [[ -d "$HOME/Library/Application Support/Microsoft/Teams" ]]; then
		run_action cache-teams CAUTION 'Teams: regenerable caches' 'Teams Cache, Application Cache, Code Cache, GPU cache, tmp' \
			'Removes regenerable Teams caches; quit Teams first.' remove_teams_cache
		run_action teams-reset DESTRUCTIVE 'Teams: local application state' 'Teams IndexedDB, databases, Local Storage, blob storage, watchdog' \
			'Resets local Teams state and may remove sessions, preferences, drafts, or offline data.' reset_teams_state
	fi

	if command -v docker >/dev/null 2>&1; then
		run_action docker-prune DESTRUCTIVE 'Docker: full system prune' 'docker system prune -af' \
			'Removes stopped containers and their writable data, unused networks, images, and build cache. Volumes are retained.' \
			docker system prune -af
	fi
}

main() {
	parse_params "$@"
	setup_colors
	validate_environment
	create_run_log
	print_mode_banner
	run_cleanups
	print_report

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
