# Downpour

**Back up your iCloud Drive and Photos to a disk you own.**

> Downpour is an independent project, not affiliated with or endorsed by Apple.
> *iCloud*, *Photos*, and *Time Machine* are trademarks of Apple Inc., used here
> only to describe what Downpour is compatible with.

A native macOS app that backs up **iCloud Drive** and **iCloud Photos** to an
external disk, with **incremental snapshots** (Time Machine-style history via
hardlinks).

It solves the two things a naive file copy gets wrong:

- **iCloud Drive** files are often dataless placeholders ("Optimize Mac
  Storage"). The engine **forces them to download** before copying, so you back
  up real bytes, not stubs. It also **follows the Desktop & Documents symlinks**
  iCloud creates, so those folders aren't silently skipped. It mirrors
  **Finder's "iCloud Drive" view**: Drive proper at the top, *plus* every
  visible app's documents (Obsidian, Pages, Keynote, …) under the app's own
  name — even though iCloud stores each as a separate on-disk container.
- **iCloud Photos** can't be safely copied from the `.photoslibrary` package.
  The engine uses Apple's **PhotoKit** to export each asset's *original*
  resources (photos, videos, Live Photo pairs, edited renders), pulling
  full-resolution originals down from iCloud as needed.

## Requirements

- macOS 14 or later.
- **Command Line Tools** are enough to build — full Xcode is *not* required
  (`xcode-select --install` if you don't have them).
- An external disk. **APFS or Mac OS Extended (HFS+) is strongly recommended** —
  these support hardlinks, so snapshot history is cheap. On exFAT the app falls
  back to a single mirror with no history (it warns you).

## Build

```sh
make app        # build + bundle + ad-hoc sign  -> dist/Downpour.app
make run        # build and launch the app
make selftest   # run the engine unit tests (no Xcode/XCTest needed)
make cli        # build the headless CLI -> dist/downpour
```

Then drag `dist/Downpour.app` to `/Applications` (optional).

## First run — grant permissions

The app is **not sandboxed** so it can read iCloud Drive and write to external
disks. macOS will still gate access:

1. **Full Disk Access** — required to read the iCloud Drive mirror.
   System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ add
   **Downpour**.
2. **Photos** — the app prompts on first Photos backup. If you miss it:
   System Settings ▸ Privacy & Security ▸ Photos ▸ enable **Downpour**
   (choose *Full Access*, not *Selected Photos*).

### Stable signing (so permissions survive rebuilds)

By default the app is **ad-hoc** signed, whose identity (a cdhash) changes on
every build — so macOS re-prompts for Full Disk Access / Photos after each
rebuild. To anchor the signature to a persistent identity:

```sh
make signing-cert   # one-time: creates a self-signed code-signing identity
                    # (asks for your login keychain password to pre-authorize codesign)
make app            # now signs with that identity
```

After this, `make app` always produces the same designated requirement, so your
granted permissions persist across rebuilds. The identity is a local self-signed
cert (created by `scripts/create-signing-cert.sh`); it's untrusted by Gatekeeper,
which is fine for a locally built app. If you skip the keychain password, the
first `make app` shows a one-time keychain dialog — click **Always Allow**.

## How backups are stored

```
<destination>/
  Drive/
    snapshots/2026-06-27-020000/...   # one dir per run (hardlinked history)
    latest -> snapshots/2026-06-27-020000
    manifest.json
  Photos/
    snapshots/2026-06-27-020000/YYYY/MM/<id>_<filename>
    latest -> ...
    manifest.json
  runs/<timestamp>.json               # per-run summaries
  last-run.json
```

Unchanged files are **hardlinked** from the previous snapshot, so each snapshot
looks like a full copy but only changed files consume new space. **To restore,
just copy files back** out of any snapshot (or `latest`) — they're plain files,
no special tool needed.

On exFAT (no hardlinks) the layout is a single `current/` mirror instead.

## Command-line usage

The headless CLI is handy for testing or scripting Drive backups:

```sh
dist/downpour --dest /Volumes/Backup/Downpour --drive --retention 10
dist/downpour --dest /Volumes/Backup/Downpour --drive-source ~/SomeFolder
dist/downpour --help
```

> Photos backup via the bare CLI is intentionally disabled — PhotoKit needs the
> signed app bundle's privacy entitlement. Use the app (or the scheduled agent)
> for Photos.

## Options & progress

The app window gives you:

- **Live progress** — overall percent, items done, copied/reused counts, total
  size, transfer speed, elapsed time and ETA, plus a per-source bar.
- **Permissions panel** — one-click Photos authorization and a shortcut to Full
  Disk Access settings, shown only when something needs granting.
- **What to back up** — iCloud Drive and/or Photos, with Photos sub-options for
  *include videos* and *include hidden*.
- **Options** — snapshot retention, verify-after-copy, notify-on-finish,
  eject-disk-after-backup, and **parallel transfers** (how many files download &
  copy at once).
- **Reveal in Finder / open logs** buttons in the header.

## Scheduled (automatic) backups

The easiest way is the **Automatic backups** switch in the app — pick *Every 6
hours*, *Every 12 hours*, or *Daily* at a chosen hour. It installs a launchd
agent that runs the headless `--backup` mode, reusing your settings and Photos
permission.

You can also manage the agent from the command line:

```sh
make install-agent                          # daily at 02:00
scripts/install-agent.sh --hour 9 --minute 30
scripts/install-agent.sh --interval 21600   # every 6 hours
make uninstall-agent
```

The agent skips quietly (exit 75, so launchd retries later) if the backup disk
isn't connected, and posts a notification when a run finishes. Logs:
`~/Library/Logs/Downpour/`.

## Project layout

```
Package.swift
Sources/
  BackupCore/            # engine (no UI) — Drive, Photos, snapshots, manifest
    Drive/               # iCloud Drive scan + download-forcing
    Photos/              # PhotoKit export
    Snapshot/            # hardlink snapshots / exFAT mirror
    Manifest/            # incremental state
    Engine/              # orchestration
  DownpourApp/       # SwiftUI app + headless --backup mode
  downpour-cli/      # headless CLI
  backup-selftest/       # self-contained test runner (no XCTest)
scripts/                 # launchd install / uninstall
Resources/               # Info.plist, entitlements
Makefile
```

## Notes & limitations

- Snapshot history (and cheap incremental dedup) requires an APFS/HFS+
  destination. Format your backup disk accordingly for best results.
- The first Photos backup downloads every original from iCloud — it can be large
  and slow. Subsequent runs only fetch new/changed assets.
- Live Photos are backed up as both the still and the paired video. Edited
  photos keep both the original and the edited render.
