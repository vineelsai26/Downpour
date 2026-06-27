# Downpour

**Back up your iCloud Drive and Photos to a disk you own.**

> Downpour is an independent project, not affiliated with or endorsed by Apple.
> *iCloud*, *Photos*, and *Time Machine* are trademarks of Apple Inc., used here
> only to describe what Downpour is compatible with.

A native macOS app (plus a headless CLI) that backs up **iCloud Drive** and
**iCloud Photos** to an external disk, with **incremental snapshots** —
Time Machine-style history via hardlinks. It forces dataless "Optimize Mac
Storage" placeholders to download first, so you back up real bytes, and exports
Photos originals through Apple's PhotoKit (not a raw copy of the library).

## Install

```sh
brew install --cask vspkg/tap/downpour
```

This installs **Downpour.app** and the `downpour` CLI. Requires **macOS 14
(Sonoma) or later**.

Downpour is locally code-signed but **not notarized**, so the cask clears the
download quarantine flag on install. If macOS still blocks the first launch,
right-click the app and choose **Open** once, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Downpour.app"
```

## First run — grant permissions

- **Full Disk Access** — to read the iCloud Drive mirror.
  System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ add **Downpour**.
- **Photos (Full Access)** — to back up your photo library. The app prompts on
  first Photos backup; or enable it under Privacy & Security ▸ Photos.

## CLI

```sh
downpour --dest /Volumes/Backup/Downpour --drive --retention 10
downpour --help
```

Photos backup runs through the app (PhotoKit needs the signed app bundle); the
CLI handles iCloud Drive.

## Releases

This repository publishes Downpour's macOS release builds. The source lives in a
private monorepo; binaries here are built from it.
