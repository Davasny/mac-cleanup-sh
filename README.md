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

## Options

| Option            | Behavior                                              |
|-------------------|-------------------------------------------------------|
| `--auto`          | Run only allowlisted `SAFE` actions without prompting |
| `--unsafe`        | Include all risk levels; requires `--auto`            |
| `--dry-run`       | Show selected actions without executing commands      |
| `--skip-docker`   | Exclude Docker cleanup                                |
| `-u`, `--update`  | Include separate Homebrew update and upgrade actions  |
| `-v`, `--verbose` | Print the complete command log                        |
| `--no-color`      | Disable colored output                                |

## Risk levels

| Risk          | Meaning                                                     | Interactive           | `--auto` | `--auto --unsafe` |
|---------------|-------------------------------------------------------------|-----------------------|----------|-------------------|
| `SAFE`        | Regenerable cache                                           | Ask                   | Run      | Run               |
| `CAUTION`     | Trash, logs, broad caches, or environment changes           | Warn and ask          | Skip     | Run               |
| `DESTRUCTIVE` | Backups, archives, application state, or stopped containers | Strongly warn and ask | Skip     | Run               |

The script refuses to run as root. It no longer deletes system cache directories, `/private/var/folders`, wget HSTS
state, or flushes DNS and inactive memory because those operations are inappropriate for routine disk cleanup.

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

The current cleanup set does not need root ownership. Any future root-owned action must elevate only its individual
command; the complete script should never be launched with `sudo`.

## Important limitations

- Quit applications before deleting their caches.
- Package caches may be required for offline or historical builds.
- `df` measurements are observations, not exact per-command savings; APFS and background writes can affect them.
- Docker prune retains volumes but deletes stopped containers and their writable layers.
- Xcode archives can contain release artifacts and dSYMs required for crash symbolication.
