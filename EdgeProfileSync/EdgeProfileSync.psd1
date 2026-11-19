@{
    RootModule           = 'EdgeProfileSync.psm1'
    ModuleVersion        = '2.1.1'
    CompatiblePSEditions = @('Core')
    GUID                 = '1bd59bae-471a-4f90-b06e-12045f6c6c53'
    Author               = 'Steven van Beek (based on EdgeProfiles by Michael Mardahl)'
    Copyright            = '(c) 2021 MSEndpointMgr, (c) 2026 Steven van Beek. MIT licensed.'
    Description          = 'Fast backup, restore and multi-machine sync of Microsoft Edge profiles (bookmarks, settings, history, collections) without passwords or cookies.'
    PowerShellVersion    = '7.4'
    FormatsToProcess     = @('EdgeProfileSync.Format.ps1xml')

    FunctionsToExport    = @(
        'Backup-EdgeProfiles'
        'Restore-EdgeProfiles'
        'Sync-EdgeProfiles'
        'Get-EdgeProfile'
        'Install-EdgeProfileExtension'
        'Remove-EdgeProfile'
        'Get-EdgeProfileSyncConfig'
        'Set-EdgeProfileSyncConfig'
        'Register-EdgeProfileSyncTask'
        'Unregister-EdgeProfileSyncTask'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('Edge', 'MicrosoftEdge', 'EdgeProfiles', 'Profiles', 'Backup', 'Restore', 'Sync', 'Bookmarks', 'OneDrive', 'Windows', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/StevenVBeek/EdgeProfileSync/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/StevenVBeek/EdgeProfileSync'
            ReleaseNotes = @'
2.1.1 - clearer console output for backup and restore: boxed header and summary, aligned table per profile.

2.1.0 - detailed progress (header, progress bars with speed and ETA, per-profile lines, summary) for backup,
restore, sync and cleanup; Backup-EdgeProfiles -Format Folder (robocopy, incremental); faster zip backups
(parallel readers, no temporary copy); unreadable files are skipped and reported instead of failing.

2.0.0 - complete rewrite of EDGEProfiles (by Michael Mardahl / MSEndpointMgr) for PowerShell 7.4+.
- Fast: copies a whitelist of profile files instead of zipping the whole User Data folder.
- Works with Edge open: consistent SQLite snapshots for export; import into profiles that are not open.
- Two-way multi-machine sync through OneDrive (or any synced folder) with a background scheduled task.
- Extension inventory, per-extension data sync and Install-EdgeProfileExtension for other machines.
- Get-EdgeProfile overview and Remove-EdgeProfile bulk cleanup.
- Passwords, cookies and sign-in tokens are never copied.
'@
        }
    }
}
