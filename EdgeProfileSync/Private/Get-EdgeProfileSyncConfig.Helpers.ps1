# Internal helpers for Get-EdgeProfileSyncConfig (not exported).

function Get-EdgeSyncDefaultConfig {
    # Module-internal: the built-in defaults, as an ordered hashtable (fresh copy on every call).
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $oneDrive = $env:OneDriveCommercial
    if ([string]::IsNullOrWhiteSpace($oneDrive)) { $oneDrive = $env:OneDrive }
    $syncRoot = if ([string]::IsNullOrWhiteSpace($oneDrive)) { $null } else { Join-Path $oneDrive 'EdgeProfileSync' }

    [ordered]@{
        SyncRoot                 = $syncRoot
        Channels                 = @('Stable')
        Categories               = @((Get-EdgeDataCategory -DefaultOnly).Name)
        IncludeProfiles          = @()
        ExcludeProfiles          = @()
        ArchiveRetention         = 10
        CloseBackgroundEdge      = $true
        RemoveDeletedProfiles    = $false
        IncludeProtectedProfiles = $false
        IntervalMinutes          = 30
    }
}

function Get-EdgeSyncConfigPath {
    # Module-internal: full path of config.json in the local data folder.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-EdgeSyncLocalDataPath) 'config.json'
}
