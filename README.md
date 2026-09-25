# mac-cleanup

> Forked from [mac-cleanup/mac-cleanup-sh](https://github.com/mac-cleanup/mac-cleanup-sh), originally published under
> the MIT License.

Developer-focused macOS cleanup with explicit risk levels, per-action reporting, and safe automatic mode.

## Usage

### Interactive mode

Offers every applicable action individually. Every prompt defaults to **No**.

```bash
./mac-cleanup.sh
```

### Automatic cache cleanup

Runs only actions classified as `SAFE`. Caution and destructive actions are reported as skipped.

```bash
./mac-cleanup.sh --auto
```

### Unsafe automatic cleanup

Runs every applicable action without prompting.

```bash
./mac-cleanup.sh --auto --unsafe
```

This may permanently remove iOS backups, Xcode archives and dSYMs, simulator data, stopped Docker containers, cloud
content caches, and application state.

### Preview

```bash
./mac-cleanup.sh --dry-run
./mac-cleanup.sh --auto --dry-run
./mac-cleanup.sh --auto --unsafe --dry-run
```

### Skip actions by code

Each cleanup action has a stable code shown in prompts and reports. Pass one or more comma-separated codes:

```bash
./mac-cleanup.sh --skip docker-prune,xcode-archives
./mac-cleanup.sh --auto --skip cache-npm,cache-pnpm
```

Prompts display the risk and code separately:

```text
[caution] [trash-user] Trash: current user
```

## Options

| Option            | Behavior                                              |
|-------------------|-------------------------------------------------------|
| `--auto`          | Run only allowlisted `SAFE` actions without prompting |
| `--unsafe`        | Include all risk levels; requires `--auto`            |
| `--dry-run`       | Show selected actions without executing commands      |
| `--skip CODES`    | Skip comma-separated action codes                     |
| `-u`, `--update`  | Include separate Homebrew update and upgrade actions  |
| `-v`, `--verbose` | Print the complete command log                        |
| `--no-color`      | Disable colored output                                |

## Risk levels

| Risk          | Meaning                                                     | Interactive           | `--auto` | `--auto --unsafe` |
|---------------|-------------------------------------------------------------|-----------------------|----------|-------------------|
| `SAFE`        | Regenerable cache                                           | Ask                   | Run      | Run               |
| `CAUTION`     | Trash, logs, broad caches, or environment changes           | Warn and ask          | Skip     | Run               |
| `DESTRUCTIVE` | Backups, archives, application state, or stopped containers | Strongly warn and ask | Skip     | Run               |

## Cleanup actions

Actions only appear when their target application, tool, or directory is available. Homebrew update and upgrade also
require `--update`.

| Code                           | Risk          | Runs with `--auto` | Action and impact                                                                                     |
|--------------------------------|---------------|--------------------|-------------------------------------------------------------------------------------------------------|
| `trash-user`                   | `CAUTION`     | No                 | Empty the current user's Trash. Files stop being recoverable through Finder.                          |
| `cache-user-library`           | `CAUTION`     | No                 | Remove all user application caches. Close applications first; TCC may protect some entries.           |
| `cache-global-library`         | `DESTRUCTIVE` | No                 | Remove machine-wide caches from `/Library/Caches`; targeted sudo is required.                         |
| `cache-system-library`         | `DESTRUCTIVE` | No                 | Attempt to remove `/System/Library/Caches`; SIP normally blocks this.                                 |
| `logs-system-asl`              | `DESTRUCTIVE` | No                 | Remove legacy ASL system logs and diagnostic history.                                                 |
| `logs-diagnostic-reports`      | `DESTRUCTIVE` | No                 | Remove machine-wide crash and diagnostic reports.                                                     |
| `logs-creative-cloud`          | `CAUTION`     | No                 | Remove machine-wide Creative Cloud logs.                                                              |
| `logs-adobe-system`            | `CAUTION`     | No                 | Remove machine-wide Adobe logs.                                                                       |
| `logs-adobegc`                 | `CAUTION`     | No                 | Remove the machine-wide Adobe GC log.                                                                 |
| `logs-mail`                    | `CAUTION`     | No                 | Remove Apple Mail diagnostic logs.                                                                    |
| `logs-simulator`               | `CAUTION`     | No                 | Remove CoreSimulator diagnostic logs.                                                                 |
| `logs-jetbrains`               | `CAUTION`     | No                 | Remove JetBrains IDE diagnostic logs.                                                                 |
| `cache-adobe-media`            | `SAFE`        | Yes                | Remove regenerable Adobe media cache. Close Adobe applications first.                                 |
| `cache-chrome`                 | `SAFE`        | Yes                | Remove Chrome's application cache. Close Chrome first.                                                |
| `ios-ipa-archives`             | `DESTRUCTIVE` | No                 | Remove archived IPA files that may no longer be downloadable.                                         |
| `ios-device-backups`           | `DESTRUCTIVE` | No                 | Permanently remove local iPhone and iPad backups.                                                     |
| `xcode-derived-data`           | `SAFE`        | Yes                | Remove Xcode indexes and build products; subsequent builds are slower.                                |
| `xcode-archives`               | `DESTRUCTIVE` | No                 | Remove Xcode release archives and dSYMs used for exports and symbolication.                           |
| `xcode-device-logs`            | `CAUTION`     | No                 | Remove iOS device diagnostic logs.                                                                    |
| `simulator-delete-unavailable` | `CAUTION`     | No                 | Delete unsupported simulator devices and their stored data.                                           |
| `simulator-erase-all`          | `DESTRUCTIVE` | No                 | Erase all simulator applications, databases, keychains, accounts, and fixtures.                       |
| `cache-gradle`                 | `SAFE`        | Yes                | Remove Gradle caches. Stop active builds first.                                                       |
| `cache-android`                | `SAFE`        | Yes                | Remove Android tooling cache.                                                                         |
| `cache-composer`               | `SAFE`        | Yes                | Clear Composer's package download cache.                                                              |
| `cache-npm`                    | `SAFE`        | Yes                | Clear npm's package cache.                                                                            |
| `cache-pnpm`                   | `SAFE`        | Yes                | Prune unreferenced packages from the pnpm store.                                                      |
| `cache-uv`                     | `SAFE`        | Yes                | Clear uv's package cache.                                                                             |
| `cache-pip`                    | `SAFE`        | Yes                | Clear pip's download and wheel caches.                                                                |
| `cache-cocoapods`              | `SAFE`        | Yes                | Clear cached CocoaPods packages.                                                                      |
| `cache-go-build`               | `SAFE`        | Yes                | Clear Go build and test caches without deleting downloaded modules.                                   |
| `cache-go-modules`             | `CAUTION`     | No                 | Remove all downloaded Go modules; unavailable versions may not be recoverable.                        |
| `cache-yarn`                   | `CAUTION`     | No                 | Clear Yarn cache; behavior can include project-local zero-install data.                               |
| `cache-poetry`                 | `SAFE`        | Yes                | Remove Poetry package caches.                                                                         |
| `cache-pyenv`                  | `CAUTION`     | No                 | Remove a validated `PYENV_VIRTUALENV_CACHE_PATH`.                                                     |
| `rubygems-cleanup`             | `DESTRUCTIVE` | No                 | Remove old installed gem versions, potentially affecting pinned scripts.                              |
| `homebrew-cleanup`             | `SAFE`        | Yes                | Remove Homebrew-managed old downloads and outdated artifacts.                                         |
| `homebrew-cache`               | `CAUTION`     | No                 | Remove all contents of the validated Homebrew download cache.                                         |
| `homebrew-repair`              | `CAUTION`     | No                 | Run `brew tap --repair`, which mutates tap Git repositories.                                          |
| `homebrew-update`              | `CAUTION`     | No                 | Fetch current Homebrew formula and cask metadata. Requires `--update`.                                |
| `homebrew-upgrade`             | `DESTRUCTIVE` | No                 | Upgrade installed packages and services. Requires `--update`.                                         |
| `cache-dropbox`                | `CAUTION`     | No                 | Remove Dropbox recovery cache after synchronization is verified.                                      |
| `cache-google-drive`           | `DESTRUCTIVE` | No                 | Remove Google Drive offline content cache after synchronization is verified.                          |
| `cache-steam`                  | `SAFE`        | Yes                | Remove Steam metadata, depot, and shader caches. Close Steam first.                                   |
| `steam-downloads`              | `DESTRUCTIVE` | No                 | Remove active and staged Steam downloads and updates.                                                 |
| `logs-steam`                   | `CAUTION`     | No                 | Remove Steam diagnostic logs.                                                                         |
| `cache-minecraft`              | `SAFE`        | Yes                | Remove Minecraft launcher web caches and mixin output.                                                |
| `logs-minecraft`               | `CAUTION`     | No                 | Remove Minecraft logs and crash reports.                                                              |
| `cache-lunar`                  | `SAFE`        | Yes                | Remove Lunar Client game and launcher caches.                                                         |
| `logs-lunar`                   | `CAUTION`     | No                 | Remove Lunar Client and offline-profile logs.                                                         |
| `logs-cacher`                  | `CAUTION`     | No                 | Remove Cacher diagnostic logs.                                                                        |
| `logs-kite`                    | `CAUTION`     | No                 | Remove logs from the discontinued KiteXcode tool.                                                     |
| `logs-wget`                    | `CAUTION`     | No                 | Remove `~/wget-log`; wget HSTS state is retained.                                                     |
| `java-heap-dumps`              | `DESTRUCTIVE` | No                 | Remove `~/*.hprof` Java heap dumps that may be valuable diagnostics.                                  |
| `cache-teams`                  | `CAUTION`     | No                 | Remove regenerable Teams caches. Close Teams first.                                                   |
| `teams-reset`                  | `DESTRUCTIVE` | No                 | Remove Teams databases, local storage, sessions, preferences, and offline state.                      |
| `docker-prune`                 | `DESTRUCTIVE` | No                 | Remove stopped containers, writable layers, unused images, networks, and build cache. Volumes remain. |

The script refuses to run as root. System-owned cache and log actions elevate only their individual commands. It does
not delete `/private/var/folders`, wget HSTS state, other users' mounted-volume Trash, or flush DNS and inactive memory.

## macOS privacy permissions

Run the script as your normal login user, not with `sudo`:

```bash
./mac-cleanup.sh
```

Some user locations, including Trash and application containers, are protected by macOS Transparency, Consent, and
Control (TCC). When access is denied, the action is reported as `protected-skipped` and cleanup continues.

`sudo` handles Unix file ownership but does not reliably bypass TCC. For protected locations, grant Full Disk Access to
the application hosting the shell:

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Enable Terminal, iTerm, OpenCode, or the relevant host application.
3. Completely restart that application.

System cache and log actions request targeted `sudo` only after the action is selected. The complete script should never
be launched with `sudo`.

## Important limitations

- Quit applications before deleting their caches.
- Package caches may be required for offline or historical builds.
- `df` measurements are observations, not exact per-command savings; APFS and background writes can affect them.
- Failed actions can still remove some files; their measured free-space change appears in the report alongside the failure status.
- The final `Total reclaimed space` line reports the observed root-filesystem free-space change for the complete run.
- Docker prune retains volumes but deletes stopped containers and their writable layers.
- Xcode archives can contain release artifacts and dSYMs required for crash symbolication.
- `/System/Library/Caches` is protected by SIP on modern macOS and its cleanup action will normally fail.
- System cache and diagnostic-log actions can disrupt services or remove troubleshooting evidence.
