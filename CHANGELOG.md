# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [2.0.0] - 2026-11-19

Complete rewrite as the `EdgeProfileSync` module (successor of `EDGEProfiles`).

### Added

- `Sync-EdgeProfiles`: two-way sync of Edge profiles between machines through a shared folder
  (OneDrive by default), with three-way change detection per profile and category, last-writer-wins
  conflict handling and a versioned archive of everything that is overwritten.
- Profiles are matched by display name across machines; profiles missing on a machine are created
  automatically.
- Data categories (`Bookmarks`, `Settings`, `SecurePreferences`, `Collections`, `History`, `Favicons`,
  `ExtensionList`, `ExtensionData`, optional `Extensions` and `Autofill`). Passwords, cookies and
  sign-in tokens are never included.
- Extension restore: full restore on the same machine; on other machines extension data is synced
  and `Install-EdgeProfileExtension` opens the store page of each missing extension in the right profile.
- `Get-EdgeProfile`: profile overview per channel (name, folder, account, last active, bookmark and
  extension counts, open in Edge, size, sync state; `-All` also lists orphan profile folders).
- `Remove-EdgeProfile`: bulk cleanup from the pipeline, with a backup first, Recycle Bin by default and a
  marker in the sync folder so other machines don't re-create the profile (`RemoveDeletedProfiles`
  removes it there too).
- Edge can stay open: export/push copies SQLite databases as consistent snapshots; import/pull applies
  to every profile that is not open in Edge.
- Change detection for `Preferences` ignores Edge's constant telemetry rewrites (engagement scores,
  counters, window position), so settings don't bounce between machines.
- `Get-EdgeProfileSyncConfig` / `Set-EdgeProfileSyncConfig`: per-user configuration
  (`%LOCALAPPDATA%\EdgeProfileSync\config.json`).
- `Register-EdgeProfileSyncTask` / `Unregister-EdgeProfileSyncTask`: per-user scheduled task (at logon,
  on workstation lock and every N minutes), headless, no admin rights required; optional installation
  of the module into the user's module folder.
- Daily log files in `%LOCALAPPDATA%\EdgeProfileSync\logs` (14 days kept).
- Pester tests.

### Changed

- Backups copy only a whitelist of files per profile instead of the complete `User Data` folder
  (tens of MB instead of gigabytes), using `robocopy` and .NET `ZipFile` instead of `Compress-Archive`.
  `-Full` keeps a whole-folder backup (minus caches) for same-machine use.
- Caches in the live profile are no longer deleted before a backup; `-FoldersToClean` is accepted and ignored.
- Default backup location is `<SyncRoot>\backups\<MachineId>`.
- Requires PowerShell 7.4 or later (Windows PowerShell 5.1 is no longer supported).

### Removed

- Backing up passwords, cookies and the `Local State` encryption key in the default (non `-Full`) backup.

## 1.x - EDGEProfiles (Michael Mardahl, MSEndpointMgr)

- **1.0.6** - Last published version of the `EDGEProfiles` module.
- **1.0.5** (2022-11-17) - Functions moved to separate files; module and functions renamed; cache
  cleaning made a function so several folders can be emptied before a backup; option to close Edge
  forcefully; backup of multiple Edge channels.
- **1.0.4** (2021-08-01) - Default destination validation bug fix.
- **1.0.2 / 1.0.3** (2021-08-01) - Exit codes replaced by breaks.
- **1.0.1** (2021-07-31) - Minor output fixes.
- **1.0.0** (2021-07-30) - Initial version: zip backup of the whole Edge `User Data` folder plus the
  profile registry keys to OneDrive, and restore with a choice how to handle existing data.
