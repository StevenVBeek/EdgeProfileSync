# EdgeProfileSync - architecture and internal contract

This is the single source of truth for how the module is put together. All code is written
against the function signatures below. If you need to change a contract, change it here too.

## Why the original was slow

`EDGEProfiles` 1.x did `Get-ChildItem -Recurse` over the whole `User Data` folder (often
10+ GB: caches, ML models, shader caches, extensions, crash dumps), **deleted** cache folders in
the live profile, and then ran `Compress-Archive` (PowerShell-level, single-threaded, slow)
over everything. v2 copies only a whitelist of files per profile (see `Private/Categories.ps1`),
typically tens of MB per profile, uses `robocopy` for directories and .NET `ZipFile` for archives,
and never touches the live profile's caches.

## Goals

1. `Backup-EdgeProfiles` / `Restore-EdgeProfiles`: fast point-in-time archive (zip), compatible in
   spirit with 1.x (same command names, `-Destination`, `-Channel`, `-CloseEdge`).
2. `Sync-EdgeProfiles`: two-way, multi-machine sync of selected categories through a shared
   folder (OneDrive by default), with 3-way change detection and versioned archive of overwritten data.
3. `Register-EdgeProfileSyncTask`: per-user scheduled task (at logon, on workstation lock, every
   N minutes), headless (no console flash), running `pwsh.exe`.
4. Never sync passwords, cookies, auth tokens or the `Local State` encryption key.
5. **PowerShell 7.4+ only** (`pwsh`). Windows PowerShell 5.1 is not supported. Use modern syntax freely
   (`??`, ternary, `ConvertFrom-Json -AsHashtable`, `-Depth`, `ForEach-Object -Parallel` where it helps).
   No external modules at runtime. Windows only.

## Edge facts the code relies on

- User data: `%LOCALAPPDATA%\Microsoft\Edge\User Data` (Stable), `...\Edge Beta\User Data`,
  `...\Edge Dev\User Data`, `...\Edge SxS\User Data` (Canary).
- Registry: `HKCU\Software\Microsoft\Edge[ Beta| Dev| SxS]\PreferenceMACs` (machine-bound MACs).
- `Local State` (JSON, in User Data root) holds `profile.info_cache` (`<dir>` -> `{ name, avatar_icon,
  user_name, gaia_id, ... }`) and `profile.profiles_order`. It **contains empty-string property
  names**, so `ConvertFrom-Json` without `-AsHashtable` fails. Use the JSON helpers below.
- Profile folders: `Default`, `Profile N`. Skip `Guest Profile`, `System Profile`.
- `Bookmarks` (plain JSON) and `EncryptedBookmarks2` (machine-bound) are both maintained by Edge.
- `Secure Preferences` / `PreferenceMACs` are machine-bound: copying them across machines makes Edge
  reset protected settings. Hence category `SecurePreferences` is `SameMachineOnly`.
- Process `msedge.exe`. With Startup Boost, background `msedge` runs without windows. WebView2
  (`msedgewebview2.exe`, used by Teams/Outlook) is a different process and must never be touched.
- SQLite files can be copied while Edge runs (verified). `Copy-EdgeSqliteSnapshot` makes that copy
  consistent (waits for no hot journal, verifies the file did not change during the copy, carries `-wal`).
  So **export/push never needs Edge closed**.
- A running Edge only has the profiles loaded that have a window (or are kept in the background).
  `Test-EdgeProfileInUse` detects a loaded profile (its History/Favicons/Web Data are held open).
  **Import/pull into a profile that is not loaded is allowed while Edge runs.** Only creating a new profile
  or removing one (both rewrite `Local State`, which Edge overwrites on exit) needs Edge fully closed.

## Code layout

- `Public/<Command>.ps1` holds exactly one exported function, named after the file (the psm1 exports
  `Public/*.ps1` basenames). Nothing else lives there.
- `Private/<Command>.Helpers.ps1` holds the internal helpers of that command.
- `Private/Core.*.ps1` shared helpers (contract below), `Private/Sync.*.ps1` sync engine/store,
  `Private/Extensions.ps1` extension inventory and pending lists, `Private/Categories.ps1` data categories.
- `EdgeProfileSync.Format.ps1xml` default table view of `Get-EdgeProfile`.
- Tests: `tests/<Area>.Tests.ps1` (Pester 5). `tests/Module.Tests.ps1` checks the manifest, exported
  functions, help and the repo-wide name guard.

## Core helper contract (`Private/Core.*.ps1`)

All paths are full paths. All functions are advanced functions (`[CmdletBinding()]`).
Every function that touches the real user environment must accept overrides so tests can point it at
a fake `User Data` folder under `$TestDrive`.

```powershell
# --- Channels / paths (Core.Paths.ps1)
Get-EdgeChannelInfo [-Channel <Stable|Beta|Dev|Canary>] [-UserDataRoot <string>]
#  -> [pscustomobject]@{ Channel; UserDataPath; RegistryKey ('HKCU\Software\Microsoft\Edge\PreferenceMACs');
#                        Installed (bool, UserDataPath exists) }
#  -UserDataRoot overrides UserDataPath (tests).
Get-EdgeSyncMachineId
#  -> string: stable id for this machine, "<COMPUTERNAME>-<first 8 chars of HKLM MachineGuid>".
Get-EdgeSyncLocalDataPath
#  -> "%LOCALAPPDATA%\EdgeProfileSync" (created if missing). Override with $env:EDGEPROFILESYNC_HOME (tests).
ConvertTo-EdgeSafeName -Name <string>
#  -> filesystem-safe name (invalid chars -> '_', trimmed, trailing dots removed, max 80 chars).

# --- JSON (Core.Json.ps1) - must handle empty property names
Read-EdgeJsonFile -Path <string>          # -> nested [hashtable]/[object[]] (ordered not required)
Write-EdgeJsonFile -Path <string> -InputObject <object> [-Depth 100]
#  Writes UTF-8 without BOM, atomically (write temp file in same folder, then replace).
#  ConvertFrom-Json -AsHashtable -Depth 200 / ConvertTo-Json -Depth 100 -Compress.

# --- Processes (Core.Process.ps1)
Get-EdgeProcessState [-Channel ...]
#  -> [pscustomobject]@{ Running (bool); HasWindows (bool); ProcessCount (int) }
#  Uses the msedge.exe path to tell channels apart (Edge Beta lives in "Edge Beta\Application").
Stop-EdgeProcess [-Channel ...] [-BackgroundOnly] [-TimeoutSeconds 15]
#  -BackgroundOnly: only stops when no msedge process of that channel has a visible window; returns $false otherwise.
#  Returns $true when Edge of that channel is no longer running.

# --- Profiles (Core.Profiles.ps1)
Get-EdgeLocalProfile [-Channel ...] [-UserDataRoot <string>]
#  -> one object per profile in Local State info_cache whose folder exists:
#     [pscustomobject]@{ Channel; Directory ('Profile 3'); Path (full); Name (display name);
#                        Key (sync key, see below); IsSignedIn (bool: user_name not empty);
#                        InfoCache (hashtable: the raw info_cache entry) }
#  Key = ConvertTo-EdgeSafeName(Name). Duplicates are resolved case-insensitively: the first by
#  profiles_order keeps the bare key, later ones get "<key> (<Directory>)".
New-EdgeLocalProfile -Name <string> [-InfoCache <hashtable>] [-Channel ...] [-UserDataRoot <string>]
#  Creates the next free "Profile N" folder, adds an info_cache entry (copied from -InfoCache minus
#  account fields: user_name, gaia_id, gaia_name, gaia_given_name, gaia_picture_file_name,
#  last_downloaded_gaia_picture_url_with_size, hosted_domain, and any key starting with
#  'edge_account' or 'signin'), sets name, appends to profiles_order. Backs up Local State to
#  "Local State.edgeprofilesync.bak" first. Edge must be closed (caller's job). Returns the profile object.

Remove-EdgeLocalProfile -Directory <string> [-Channel ...] [-UserDataRoot <string>] [-Permanent] [-KeepFolder]
#  Unregisters from Local State (info_cache, profiles_order, last_active_profiles, last_used), backs up
#  Local State, sends the folder to the Recycle Bin (default), -Permanent deletes. Refuses 'Default'.
#  SupportsShouldProcess, ConfirmImpact High. Edge must be fully closed (caller's job).
Test-EdgeProfileInUse -Path <profile folder>     # -> $true when a running Edge has the profile loaded
#  Get-EdgeLocalProfile objects also carry: Account (user_name or ''), LastActiveUtc ([datetime] UTC or $null).

# --- Copy / fingerprint (Core.Files.ps1)
Copy-EdgeItem -Source <string> -Destination <string> [-Directory]
#  File: copy with overwrite, preserve LastWriteTime, create parent dirs, retry 3x on IOException
#  (OneDrive / Edge locks). Directory: robocopy /MIR /R:2 /W:1 /MT:8 /NJH /NJS /NP /NFL /NDL,
#  exit code < 8 = success, otherwise throw. Returns nothing.
Copy-EdgeSqliteSnapshot -Source <string> -Destination <string> [-MaxAttempts 10]
#  Consistent copy of a SQLite db Edge may have open (see "Edge facts"). Use for every file of a
#  Sqlite category (files inside a Sqlite category *directory*: robocopy the dir, then re-copy each
#  '*.db'/'*SQLite*' file in it with this function). Throws when the db keeps changing.
Get-EdgeItemFingerprint -Path <string>
#  File: SHA256 hex of content. Directory: SHA256 over sorted "relpath|length|lastwriteutc ticks" lines.
#  Missing path: $null.
Move-EdgeItemAside -Path <string> -BackupRoot <string>
#  Moves file/dir (if it exists) into BackupRoot (keeps name, adds suffix if taken). Never deletes.

# --- Logging (Core.Log.ps1)
Write-EdgeSyncLog -Message <string> [-Level Info|Warning|Error|Verbose]
#  Writes to Write-Verbose/Write-Warning/Write-Error as appropriate AND appends
#  "yyyy-MM-ddTHH:mm:ss level message" to "<LocalDataPath>\logs\EdgeProfileSync-yyyyMMdd.log".
#  Keeps 14 days of logs (prune on first write per session).
```

## Config (`Get/Set-EdgeProfileSyncConfig`, file `<LocalDataPath>\config.json`)

```json
{
  "SyncRoot": "C:\\Users\\me\\OneDrive\\EdgeProfileSync",
  "Channels": ["Stable"],
  "Categories": ["Bookmarks","Settings","SecurePreferences","Collections","History","Favicons","ExtensionList","ExtensionData"],
  "IncludeProfiles": [],          // empty = all; matched against display Name or Key (wildcards ok)
  "ExcludeProfiles": [],
  "ArchiveRetention": 10,
  "RemoveDeletedProfiles": false, // also delete profiles locally that were removed on another machine         // versions kept per profile/category in the store archive
  "CloseBackgroundEdge": true,    // allow stopping windowless (Startup Boost) Edge to restore
  "IntervalMinutes": 30
}
```
Default `SyncRoot`: `$env:OneDriveCommercial`, else `$env:OneDrive`, joined with `EdgeProfileSync`.
`Get-EdgeProfileSyncConfig` returns defaults merged with the file. `Sync-EdgeProfiles` parameters
override config values.

## Sync store layout (`<SyncRoot>`)

```
<SyncRoot>\
  store\<Channel>\<ProfileKey>\
      profile.json                 # { Name, Key, InfoCache (sanitised), UpdatedUtc, Machine }
      manifest.json                # { Categories: { <Cat>: { Fingerprint, UpdatedUtc, Machine } } }
      <Category>\<files/dirs as in profile>
  archive\<Channel>\<ProfileKey>\<Category>\<yyyyMMdd-HHmmss>-<Machine>\...
  machines\<MachineId>.json        # last sync summary per machine (time, version, profiles, errors)
  backups\<MachineId>\Edge<Channel>-<yyyyMMdd-HHmmss>.zip   # Backup-EdgeProfiles default target
```

## Local sync state (`<LocalDataPath>\state.json`)

```json
{ "Items": { "Stable|Work|Bookmarks": { "Fingerprint": "...", "SyncedUtc": "..." } } }
```

## Sync algorithm (per channel, per profile key, per category)

```
L = fingerprint(local category)   R = store manifest fingerprint   B = state base fingerprint
L == R                  -> in sync; update base = L
L != B and R == B       -> local changed  -> PUSH
L == B and R != B       -> remote changed -> PULL
L != B and R != B       -> conflict -> newer wins (local = max LastWriteTimeUtc of its files,
                           remote = manifest UpdatedUtc); loser is archived (push archives the old
                           store copy; pull moves local files aside into
                           <LocalDataPath>\replaced\<timestamp>\<Directory>\)
no base, local only     -> PUSH;  no base, remote only -> PULL (creating the profile if missing)
no base, both differ    -> conflict rule
```
- PUSH: archive current store copy (if any), copy local -> store, update manifest + base.
- PULL into an existing profile: allowed when `Test-EdgeProfileInUse` is false, even while Edge runs.
  If the profile is loaded: when Edge has no windows and `CloseBackgroundEdge` -> Stop-EdgeProcess
  -BackgroundOnly and continue; otherwise skip with an Info log, retry next run. Move aside
  `MoveAsideOnRestore` files, copy store -> local, update base.
- PULL that has to create a profile: needs Edge of that channel not running at all (same background rule).
- PUSH: always allowed, Edge open or not; Sqlite files via `Copy-EdgeSqliteSnapshot`.
- Tombstones: `store\<Channel>\<ProfileKey>\deleted.json` = `{ Key, Name, DeletedUtc, Machine }` written by
  `Remove-EdgeProfile`. Sync never pushes to or re-creates a tombstoned key, and stops reporting it.
  If config `RemoveDeletedProfiles` is true (default false) and the profile exists locally and Edge is
  fully closed, sync removes it locally too (Remove-EdgeLocalProfile, Recycle Bin) and logs it.
  A profile that is created again later with the same name (no base in state, local only) clears the
  tombstone on push only when its local folder is newer than DeletedUtc.
- `SameMachineOnly` categories: push always; pull only when manifest `Machine` == this machine.
- `ExtensionList`: generated by `Get-EdgeExtensionInventory` (see "Extensions" below). On pull, compare with
  the local inventory and write the pending-install list for ids missing locally (see below), log them.
- `ExtensionData` (`PerExtension`): every extension id is its own sync item, key
  `<Channel>|<ProfileKey>|ExtensionData:<id>`, content = `Local Extension Settings\<id>` +
  `Sync Extension Settings\<id>`; store path `<Category>\<id>\<dir>\`. PULL of an id happens only when that
  extension is installed locally (per local inventory); otherwise the item is left untouched (no base update)
  so it is pulled on a later run after the user installed the extension. Policy-installed extensions are skipped.

## Extensions (`Private/Extensions.ps1`)

Edge does not allow silently installing an extension into one profile without machine-bound MACs or
policy, so cross-machine extension restore is: inventory -> pending list -> user-assisted install -> data.

```powershell
Get-EdgeExtensionInventory -ProfilePath <string>
#  -> objects { Id; Name; Version; Enabled (bool); Source ('EdgeStore'|'ChromeStore'|'Policy'|'Unpacked'|'Component'|'Other');
#               StoreUrl (string or $null) }
#  Reads extensions.settings from 'Secure Preferences' and 'Preferences' (merged). Name/version/update_url from
#  settings.manifest, or else from Extensions\<id>\<version>\manifest.json (resolve __MSG_x__ names via
#  _locales\<default_locale>\messages.json when cheap). Skip component/default-installed extensions
#  (location 5 = component, 10 = external component; was_installed_by_default = true).
#  Source: update_url containing 'edge.microsoft.com' -> EdgeStore
#          (StoreUrl https://microsoftedge.microsoft.com/addons/detail/<id>);
#          'clients2.google.com' or 'chromewebstore' -> ChromeStore (https://chromewebstore.google.com/detail/<id>);
#          location 4 = unpacked; location 3/9 (external policy) or install via policy -> Policy (never reinstall);
Get-EdgePendingExtension [-Channel] [-ProfileKey]       # reads pending lists
Set-EdgePendingExtension -Channel -ProfileKey -Extension <objects[]>   # replaces the list (empty -> delete file)
#  File: <LocalDataPath>\pending-extensions\<Channel>\<ProfileKey>.json
```

Public command `Install-EdgeProfileExtension [-Channel] [-Profile <name/key, wildcards>] [-PassThru] [-WhatIf]`
: for each profile with pending extensions, re-checks the local inventory (drops ones now
installed, updates the pending file) and starts `msedge.exe --profile-directory="<Directory>" <StoreUrl...>`
so the user only has to click "Get". Unpacked/Other entries are only listed. Chrome Web Store entries come with
a note that "Allow extensions from other stores" must be enabled once. Interactive command; never run by the task.

Restore-EdgeProfiles: same machine + `Extensions` + `SecurePreferences` in backup -> full extension restore.
Otherwise restores `ExtensionData` for every id (Edge keeps the data folder until the extension is installed;
if it is garbage-collected the next Sync re-applies it) and writes the pending list.
`Get-EdgeProfile` shows a `PendingExtensions` count.
- Deletions are never propagated (a profile or bookmark removed on one machine is not deleted elsewhere
  by the sync engine; bookmarks are file-level so a pushed Bookmarks file does reflect removals).
- Profiles that are signed in with Edge's own sync are synced as well unless excluded; README warns
  that using both on one profile makes the two sync engines fight.
- A lock file `<SyncRoot>\store\.lock-<MachineId>` is not needed; per-category copies are atomic enough
  (write into `<Category>.tmp-<MachineId>` then rename).

`Sync-EdgeProfiles` returns one result object per (Channel, Profile, Category):
`[pscustomobject]@{ Channel; Profile; Category; Action ('InSync','Push','Pull','Skipped','Conflict-Push','Conflict-Pull','Error'); Reason }`
and supports `-WhatIf`.

## Profile overview and bulk cleanup

`Get-EdgeProfile [-Channel] [-Name <wildcards>] [-IncludeSize] [-All]`
-> `Channel, Directory, Name, Key, Account, IsSignedIn, LastActiveUtc (+ LastActive local time), InUse,
   BookmarkCount (count of url nodes in Bookmarks JSON), ExtensionCount, PendingExtensions, SizeMB (only with
   -IncludeSize: whole profile folder), SyncState ('Synced'|'LocalOnly'|'Deleted elsewhere'|'' when no sync
   root)`. Default table view: Name, Directory, Account, LastActive, BookmarkCount, SizeMB, InUse.
`-All` also lists profile folders on disk that are missing from Local State (orphans: Name = '(orphan)').

`Remove-EdgeProfile` (new public command)
- Input: `-Name`/`-Key`/`-Directory` (wildcards) or pipeline objects from `Get-EdgeProfile`
  (ValueFromPipelineByPropertyName on Directory + Channel). Typical cleanup:
  `Get-EdgeProfile | Where-Object LastActiveUtc -lt (Get-Date).AddMonths(-6) | Remove-EdgeProfile`
  or interactive selection with `Out-ConsoleGridView` (module Microsoft.PowerShell.ConsoleGuiTools, optional).
- SupportsShouldProcess, ConfirmImpact High (prompts per profile unless -Confirm:$false / -Force).
- Default: first a backup zip of the profiles being removed (`Backup-EdgeProfiles -Profile ... -Category All`,
  to the normal backups folder), `-SkipBackup` to skip. Then `Remove-EdgeLocalProfile` (Recycle Bin;
  `-Permanent` to delete). Requires Edge of that channel fully closed: refuses otherwise, `-CloseEdge` stops it.
- Unless `-LocalOnly`, writes a tombstone to the sync store (`Set-EdgeSyncTombstone`, Private/Sync.Store.ps1,
  `Set-EdgeSyncTombstone -SyncRoot -Channel -ProfileKey -Name`, and
  `Get-EdgeSyncTombstone -SyncRoot -Channel [-ProfileKey]`) so other machines do not re-create it.
- Collects all pipeline input first and processes in `end {}` (one Edge check, one Local State rewrite per profile).
- Orphan folders (from `Get-EdgeProfile -All`) are removable too (folder only).
- Returns a summary object per profile with -PassThru.
