# EdgeProfileSync

Fast backup, restore and **multi-machine sync** of Microsoft Edge profiles for PowerShell 7.

EdgeProfileSync keeps the bookmarks, settings, history, collections and extension data of all your
Edge profiles the same on every PC you use, through a folder that is already synced between them
(OneDrive by default). It is made for people with many Edge profiles that are *not* signed in to
Edge's own sync (local profiles, profiles per customer or project, profiles with accounts that
don't allow Edge sync), who don't want to maintain each profile by hand on every machine.

Passwords, cookies and sign-in tokens are **never** copied.

It is version 2 of [EDGEProfiles](https://github.com/MSEndpointMgr/EDGEProfiles) by Michael Mardahl
(MSEndpointMgr): the `Backup-EdgeProfiles` / `Restore-EdgeProfiles` commands are still there, the
engine underneath is new.

## Why v2

EDGEProfiles 1.x zipped the complete `User Data` folder with `Compress-Archive`. That folder is often
10+ GB (caches, ML models, shader caches, crash dumps, extension binaries), so a backup took a very
long time, and it emptied cache folders in the live profile first.

v2 copies only a **whitelist of files per profile** (see the table below), typically tens of MB per
profile instead of gigabytes, uses `robocopy` for folders and .NET `ZipFile` for archives, and never
touches the caches of the live profile. A backup of two dozen profiles takes about 15 seconds,
with Edge open.

On top of that, v2 adds two-way sync between machines and a scheduled task that runs it in the background.

## Requirements

- Windows 10 or Windows 11
- PowerShell 7.4 or later (`pwsh`). Windows PowerShell 5.1 is not supported.
- Microsoft Edge (Stable, Beta, Dev or Canary)
- For sync: OneDrive (personal or for Business) or any other folder that is synced between your PCs
  (a file share or another sync client works too)
- No admin rights needed

## Install

From the PowerShell Gallery:

```powershell
Install-PSResource EdgeProfileSync -Scope CurrentUser
Update-PSResource EdgeProfileSync      # later, to update
```

Or from a clone of this repository: `Import-Module .\EdgeProfileSync\EdgeProfileSync.psd1`. In that case
`Register-EdgeProfileSyncTask -InstallModuleForUser` (see below) copies the module to
`Documents\PowerShell\Modules\EdgeProfileSync\<version>`, so the scheduled task no longer depends on
the cloned folder.

## Quick start

### Backup and restore (one machine)

```powershell
# Back up the default categories of all Stable profiles to OneDrive\EdgeProfileSync\backups\<machine>
Backup-EdgeProfiles

# Edge can stay open: databases are copied as consistent snapshots
Backup-EdgeProfiles -Destination D:\EdgeBackup -Category All

# Restore; profiles that are open in Edge are skipped (close them or use -CloseEdge)
Restore-EdgeProfiles -Path D:\EdgeBackup\EdgeStable-20261119-101500.zip
Get-Help Restore-EdgeProfiles -Examples
```

### Set up sync on every PC

Run this once on **each** PC, with the same sync folder:

```powershell
Import-Module .\EdgeProfileSync\EdgeProfileSync.psd1

# 1. Choose the shared folder (default: OneDrive for Business, else personal OneDrive \EdgeProfileSync)
Set-EdgeProfileSyncConfig -SyncRoot "$env:OneDrive\EdgeProfileSync"

# 2. Optional: try a dry run to see what would happen
Sync-EdgeProfiles -WhatIf -Verbose

# 3. Install the module for your user and register the background task
Register-EdgeProfileSyncTask -InstallModuleForUser
```

The task (`\EdgeProfileSync\EdgeProfileSync - <user>` in Task Scheduler) runs as you, only while you
are logged on, without a console window:

- at logon (after a 1 minute delay),
- when you lock the workstation,
- every 30 minutes (`Set-EdgeProfileSyncConfig -IntervalMinutes 15`, then
  `Register-EdgeProfileSyncTask -Force` to change it).

Other useful settings:

```powershell
Get-EdgeProfileSyncConfig                                         # show the effective configuration
Set-EdgeProfileSyncConfig -ExcludeProfiles 'Work*'                # never sync these profiles
Set-EdgeProfileSyncConfig -IncludeProfiles 'Personal', 'Projects' # only sync these profiles
Set-EdgeProfileSyncConfig -Categories Bookmarks, Settings, Collections
Set-EdgeProfileSyncConfig -Channels Stable, Beta
Unregister-EdgeProfileSyncTask                                    # stop the background sync on this PC
```

The configuration is stored per user and per machine in `%LOCALAPPDATA%\EdgeProfileSync\config.json`.

## Examples

### Look around

```powershell
# All profiles of Edge Stable: name, folder, account, last used, bookmarks, open in Edge
Get-EdgeProfile

# Include the size on disk, sorted by last use (oldest first)
Get-EdgeProfile -IncludeSize | Sort-Object LastActiveUtc | Format-Table Name, Directory, LastActive, SizeMB

# Find a profile by name (wildcards work) and show every property
Get-EdgeProfile -Name 'Work*' | Format-List *

# Profiles of Edge Beta and Dev as well
Get-EdgeProfile -Channel Stable, Beta, Dev

# Which profiles are signed in with an account, and which are local only
Get-EdgeProfile | Group-Object IsSignedIn | Select-Object Name, Count

# Export the overview to CSV
Get-EdgeProfile -IncludeSize | Select-Object Name, Directory, Account, LastActive, BookmarkCount, SizeMB |
    Export-Csv "$HOME\Desktop\edge-profiles.csv" -NoTypeInformation
```

### Back up

```powershell
# Default categories of every Stable profile to <SyncRoot>\backups\<machine>
Backup-EdgeProfiles

# One profile only, to a USB drive
Backup-EdgeProfiles -ProfileName 'Personal' -Destination E:\EdgeBackup

# Only bookmarks and settings of all profiles, no date in the file name (overwrites the previous one)
Backup-EdgeProfiles -Category Bookmarks, Settings -AddDate $false

# Everything, including extension binaries and autofill data
Backup-EdgeProfiles -Category All

# Large backups: a plain folder (robocopy) instead of a zip - much faster with antivirus,
# and with -AddDate $false the same folder is updated incrementally (only changes are copied)
Backup-EdgeProfiles -Category All -Format Folder -AddDate $false -Destination D:\EdgeBackup

# A full copy of User Data minus caches (like 1.x, but much smaller and faster)
Backup-EdgeProfiles -Full -Destination D:\EdgeBackup

# Keep only the 5 newest backups in the destination
Backup-EdgeProfiles -Retention 5

# Get the result object (path, size, duration) for scripting
$backup = Backup-EdgeProfiles -PassThru
$backup.Path

# Silence the progress bars (status lines go to the host and can be dropped with 6>$null)
$ProgressPreference = 'SilentlyContinue'
Backup-EdgeProfiles 6>$null
```

Backup, restore, sync and cleanup show what they are doing: a boxed header with source, target and
Edge state, a progress bar with percentage, size, speed and remaining time, an aligned table with one
row per profile and a total, and a boxed summary at the end. The scheduled task runs `Sync-EdgeProfiles -Quiet`, which only writes the log.

**How long does a backup take?** Measured with 24 profiles, Edge open, real-time antivirus on:

| Backup | Size | Time |
|---|---|---|
| Default categories, zip | 435 MB in 440 files | 15 s |
| `-Category All`, zip (extension binaries: 39,000 files) | 2.65 GB | 4.5 min |
| `-Category All -Format Folder` | 2.65 GB | 1 min |
| `-Category All -Format Folder -AddDate $false`, second run | only changes | 18 s |

Antivirus scans every file the first time it is opened, which makes zipping tens of thousands of small
extension files slow; robocopy (`-Format Folder`) is not affected the same way.

### Restore

**Start fresh on a PC from a backup** (old profiles out, exactly the profiles of the backup in):

```powershell
$backup = "$env:OneDrive\Edge_Backup\EdgeStable"

# 1. Preview: what would happen
Restore-EdgeProfiles -Path $backup -ExistingDataAction Rename -CloseEdge -WhatIf

# 2. Do it: Edge is closed, the current "User Data" is renamed to "User Data-<timestamp>" (nothing is
#    deleted) and a fresh one is built with the profiles from the backup
Restore-EdgeProfiles -Path $backup -ExistingDataAction Rename -CloseEdge

# 3. On another PC than the one the backup came from: reinstall the extensions (one click each)
Install-EdgeProfileExtension

# 4. Everything fine? Delete the old folder (the restore summary shows its path)
Remove-Item "$env:LOCALAPPDATA\Microsoft\Edge\User Data-20261119-133140" -Recurse
```

Use `-ExistingDataAction Remove` instead of `Rename` to delete the old User Data automatically after a
successful restore. No separate cleanup is needed beforehand.

Other restores:

```powershell
# Restore from a folder backup (made with -Format Folder) works the same way
Restore-EdgeProfiles -Path D:\EdgeBackup\EdgeStable

# Restore everything from a backup into the existing profiles (files that are replaced are kept
# in "User Data\EdgeProfileSync-replaced\<timestamp>")
Restore-EdgeProfiles -Path D:\EdgeBackup\EdgeStable-20261119-101500.zip

# Preview first
Restore-EdgeProfiles -Path D:\EdgeBackup\EdgeStable-20261119-101500.zip -WhatIf

# Only the bookmarks of one profile
Restore-EdgeProfiles -Path $backup.Path -ProfileName 'Personal' -Category Bookmarks

# Close Edge automatically (also needed to restore profiles that are open or don't exist yet)
Restore-EdgeProfiles -Path $backup.Path -CloseEdge

# Start clean: rename the current User Data aside, then restore
Restore-EdgeProfiles -Path $backup.Path -ExistingDataAction Rename -CloseEdge

# Same machine, full restore including extensions and protected settings
Backup-EdgeProfiles -Category All -Destination D:\EdgeBackup
Restore-EdgeProfiles -Path (Get-ChildItem D:\EdgeBackup\*.zip | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -ImportRegistry -CloseEdge

# A backup made with EDGEProfiles 1.x still restores
Restore-EdgeProfiles -Path .\EdgeStable-UserData19November2026-me.zip -REGSource .\EdgeStable-ProfilesRegistry19November2026-me.reg -CloseEdge
```

### Sync between PCs

```powershell
# One-time setup on every PC
Set-EdgeProfileSyncConfig -SyncRoot "$env:OneDrive\EdgeProfileSync"
Register-EdgeProfileSyncTask

# Run a sync now and see what happened per profile and category
Sync-EdgeProfiles | Where-Object Action -ne 'InSync' | Format-Table Profile, Category, Action, Reason

# Dry run with details
Sync-EdgeProfiles -WhatIf -Verbose

# Only send this PC's changes (for example before reinstalling it)
Sync-EdgeProfiles -Mode PushOnly

# Only take changes from the other PCs
Sync-EdgeProfiles -Mode PullOnly

# Sync just a few profiles or categories this time
Sync-EdgeProfiles -IncludeProfile 'Personal', 'Project*' -Category Bookmarks, Collections

# Never sync profiles that use Edge's own sync
Set-EdgeProfileSyncConfig -ExcludeProfiles 'Personal (Edge sync)', 'Work account'

# Leave history out of the sync, keep everything else
$cats = (Get-EdgeProfileSyncConfig).Categories | Where-Object { $_ -ne 'History' }
Set-EdgeProfileSyncConfig -Categories $cats

# Sync every 15 minutes instead of 30
Set-EdgeProfileSyncConfig -IntervalMinutes 15
Register-EdgeProfileSyncTask -Force

# Keep 25 old versions per profile and category in the archive
Set-EdgeProfileSyncConfig -ArchiveRetention 25

# Check the background task
Get-ScheduledTask -TaskPath '\EdgeProfileSync\' | Get-ScheduledTaskInfo

# Stop syncing on this PC
Unregister-EdgeProfileSyncTask
```

### Extensions

```powershell
# Which profiles still miss extensions that are installed on another PC
Get-EdgeProfile | Where-Object PendingExtensions -gt 0 | Format-Table Name, PendingExtensions

# Open the store pages of all missing extensions, per profile (click "Get" on each)
Install-EdgeProfileExtension

# Only for one profile
Install-EdgeProfileExtension -ProfileName 'Personal'

# See the list without opening Edge
Install-EdgeProfileExtension -WhatIf -PassThru
```

### Clean up profiles

```powershell
# Profiles not used for a year: review, then remove (asks per profile, backup first, Recycle Bin)
$old = Get-EdgeProfile | Where-Object LastActiveUtc -lt (Get-Date).AddYears(-1)
$old | Format-Table Name, Directory, LastActive
$old | Remove-EdgeProfile -CloseEdge

# Remove by name, without prompts
Remove-EdgeProfile -Name 'Test A', 'Test B' -Force

# Profiles without any bookmarks that are not signed in
Get-EdgeProfile | Where-Object { $_.BookmarkCount -eq 0 -and -not $_.IsSignedIn } | Remove-EdgeProfile

# Orphaned profile folders Edge no longer lists (often hundreds of MB)
Get-EdgeProfile -All -IncludeSize | Where-Object IsOrphan | Remove-EdgeProfile -Force

# Remove on this PC only; other PCs keep the profile and the sync folder keeps it too
Remove-EdgeProfile -Name 'Old project' -LocalOnly

# Also clean up profiles that were removed on another PC
Set-EdgeProfileSyncConfig -RemoveDeletedProfiles $true

# Interactive selection (Install-PSResource Microsoft.PowerShell.ConsoleGuiTools)
Get-EdgeProfile -IncludeSize | Out-ConsoleGridView | Remove-EdgeProfile
```

## What is and isn't synced

| Category | Default | What | Notes |
|---|---|---|---|
| `Bookmarks` | yes | Favorites / bookmarks bar | Whole file: removals are carried over too |
| `Settings` | yes | `Preferences`, spell-check dictionary, profile picture | Profile settings, appearance, site permissions |
| `SecurePreferences` | yes | `Secure Preferences` | Start pages, search engine, extension registration. **Same machine only** (machine-bound) |
| `Collections` | yes | Edge Collections | SQLite: copied as a consistent snapshot, also while Edge runs |
| `History` | yes | Browsing history, top sites, address bar shortcuts | SQLite: copied as a consistent snapshot, also while Edge runs |
| `Favicons` | yes | Site icons for bookmarks and history | SQLite: copied as a consistent snapshot, also while Edge runs |
| `ExtensionList` | yes | Generated inventory of installed extensions | Drives the reinstall list on other machines |
| `ExtensionData` | yes | Settings and local data of each extension | Applied once the extension is installed |
| `Extensions` | no | Extension binaries | Large; same-machine restore only |
| `Autofill` | no | Addresses and form data (`Web Data`) | Stored card numbers are machine-bound and will not decrypt |

**Never** included, in any category: passwords (`Login Data`), cookies and network state, sign-in
tokens, the `Local State` encryption key, caches, sessions, service workers, IndexedDB and Local Storage.
Passwords and cookies are encrypted with a key that is bound to the machine and user (DPAPI), so they
would be useless on another PC anyway. Use Edge sync, a password manager or export/import for passwords.

## How sync works

Every machine pushes its changes to and pulls changes from the store in the sync folder:

```
<SyncRoot>\
  store\<Channel>\<Profile>\<Category>\...    current version of every profile and category
  archive\<Channel>\<Profile>\<Category>\...  previous versions (default: last 10)
  machines\<MachineId>.json                   last sync result per machine
  backups\<MachineId>\                        default target of Backup-EdgeProfiles
```

- **Three-way comparison per profile and category.** Each machine remembers the fingerprint of what it
  last synced. If only the local copy changed it is pushed, if only the store changed it is pulled,
  if both are equal nothing happens.
- **Last writer wins per category.** When both sides changed, the newer one wins. Nothing is lost:
  an overwritten store version goes to `archive\`, overwritten local files are moved to
  `%LOCALAPPDATA%\EdgeProfileSync\replaced\`.
- **Edge can stay open.** Pushing (export) always works: SQLite databases are copied as consistent
  snapshots. Pulling (import) works for every profile that is *not open* in Edge at that moment; a
  profile with an open window keeps its changes in memory and would overwrite the import when it closes,
  so that pull is retried at the next run. Windowless background Edge (Startup Boost) is stopped for
  this when `CloseBackgroundEdge` is on (the default); Edge with open windows is never closed.
  Creating or removing a profile rewrites `Local State`, which needs Edge fully closed.
- **Settings noise is ignored.** Edge rewrites `Preferences` constantly with engagement scores, tracker
  counters, window position and similar state. Change detection ignores that, so only real setting
  changes travel between machines (the whole file is still copied when it does).
- **Profiles are matched by display name**, not by folder name: "Personal" may be `Profile 3` on one PC
  and `Profile 7` on another.
- **New profiles appear automatically.** A profile that exists in the store but not on this machine is
  created (new `Profile N` folder, same name and avatar) and filled at the next pull.

## Profile overview and cleanup

```powershell
Get-EdgeProfile                         # Name, Directory, Account, LastActive, Bookmarks, InUse
Get-EdgeProfile -IncludeSize | Sort-Object LastActiveUtc | Format-Table Name, LastActive, SizeMB, SyncState
Get-EdgeProfile -All                    # also profile folders that Edge no longer knows (orphans)

# Remove profiles not used for six months (asks per profile; backup zip first; folder to Recycle Bin)
Get-EdgeProfile | Where-Object LastActiveUtc -lt (Get-Date).AddMonths(-6) | Remove-EdgeProfile

# Pick interactively (needs: Install-PSResource Microsoft.PowerShell.ConsoleGuiTools)
Get-EdgeProfile | Out-ConsoleGridView | Remove-EdgeProfile
```

`Remove-EdgeProfile` needs Edge closed (`-CloseEdge` stops it), never removes `Default`, and leaves a
marker in the sync folder so other machines don't bring the profile back. To also remove such profiles
on your other machines automatically: `Set-EdgeProfileSyncConfig -RemoveDeletedProfiles $true` (off by
default). Use `-LocalOnly` to remove a profile on one machine only, `-Permanent` to skip the Recycle Bin.

## Extensions

Extensions are restored wherever Edge allows it:

- **Same machine** (restore of your own backup): with the `Extensions` and `SecurePreferences`
  categories in the backup, extensions are fully restored, including their registration.
- **Other machine**: the extension *data* (`ExtensionData`) is synced, and the list of missing extensions
  is kept per profile. Run

  ```powershell
  Install-EdgeProfileExtension            # all profiles with missing extensions
  Install-EdgeProfileExtension -Profile 'Personal'
  ```

  It opens the store page of every missing extension in the right profile, so you only click **Get**
  for each. Extensions from the Chrome Web Store need *Allow extensions from other stores* to be
  enabled once in that profile. As soon as an extension is installed, the next sync applies its data
  (settings, logins stored by the extension itself, etc.). Extensions installed by policy are skipped:
  your organization installs those anyway. `Get-EdgeProfile` shows how many extensions are pending per profile.

Why no silent install on another machine? Edge protects the list of installed extensions with MACs
that are bound to the machine (`Secure Preferences` / `PreferenceMACs`): a copied registration is
detected and reset. The only supported way to force-install an extension is policy
(`ExtensionInstallForcelist`), which needs admin rights and applies to *all* profiles, not to one.

## Limitations

- **Protected settings are machine-bound.** Start pages, default search engine and extension
  registration live in `Secure Preferences`, which only restores on the machine it came from. On other
  machines Edge keeps its own values for these.
- **Extensions need one click per extension** on another machine (see above).
- **Passwords and cookies are never synced**, so you sign in to websites once per machine.
- **Don't combine with Edge's built-in sync on the same profile.** Both engines would write the same
  bookmarks and settings and fight over them. Exclude profiles that use Edge sync
  (`Set-EdgeProfileSyncConfig -ExcludeProfiles ...`) or turn Edge sync off for them.
- **Deleting a profile by hand (in Edge) is not propagated**; use `Remove-EdgeProfile` for that.
  Deleted bookmarks inside a profile *are* propagated, because the bookmarks file is synced as a whole.
- **Changes are per category, not merged.** If you add a bookmark on two PCs between two syncs, the
  newer bookmarks file wins and the other one is archived (not merged).
- Windows only; only the current user's profiles.

## Troubleshooting

- **Logs**: `%LOCALAPPDATA%\EdgeProfileSync\logs\EdgeProfileSync-yyyyMMdd.log` (14 days are kept).
- **Dry run**: `Sync-EdgeProfiles -WhatIf -Verbose` shows per profile and category what would be pushed,
  pulled or skipped, and why.
- **A profile is not updated**: it was open in Edge. Close its window(s), then run `Sync-EdgeProfiles`
  or lock the PC. New profiles from another PC appear after Edge was fully closed once.
- **Task status**: open Task Scheduler, folder `EdgeProfileSync`, or run
  `Get-ScheduledTask -TaskPath '\EdgeProfileSync\' | Get-ScheduledTaskInfo`.
- **Restore an older version**: copy it from `<SyncRoot>\archive\...` or from
  `%LOCALAPPDATA%\EdgeProfileSync\replaced\...` back into the profile while Edge is closed.
- **Start over on one machine**: `Unregister-EdgeProfileSyncTask`, then remove
  `%LOCALAPPDATA%\EdgeProfileSync\state.json`. The next sync compares everything again (conflicts are
  resolved by "newer wins").

## Credits and license

Based on [EDGEProfiles](https://github.com/MSEndpointMgr/EDGEProfiles) by Michael Mardahl
(MSEndpointMgr), MIT licensed. Version 2 is maintained
by Steven van Beek and released under the same [MIT license](LICENSE).
