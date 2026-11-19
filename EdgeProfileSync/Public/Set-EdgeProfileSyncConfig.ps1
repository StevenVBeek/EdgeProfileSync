function Set-EdgeProfileSyncConfig {
    <#
    .SYNOPSIS
        Changes the EdgeProfileSync configuration of the current user on this machine.

    .DESCRIPTION
        Updates "<LocalDataPath>\config.json" (by default %LOCALAPPDATA%\EdgeProfileSync\config.json).
        Only the parameters you pass are changed; all other settings keep their current value (or the
        built-in default when they were never set). See Get-EdgeProfileSyncConfig for the settings.

        Validation:
        - SyncRoot is expanded to a full path and created when it does not exist yet.
        - Channels must be Stable, Beta, Dev or Canary.
        - Categories must be known data categories (Bookmarks, Settings, SecurePreferences,
          Collections, History, Favicons, ExtensionList, Extensions, Autofill).

        Run this on every machine that should take part in the sync, with the same SyncRoot
        (for example the same folder inside OneDrive).

    .PARAMETER SyncRoot
        Shared folder used to sync profiles between machines, e.g. "$env:OneDrive\EdgeProfileSync".

    .PARAMETER Channels
        Edge channels to sync.

    .PARAMETER Categories
        Data categories to sync. Passwords and cookies are never part of any category.

    .PARAMETER IncludeProfiles
        Only sync profiles whose display name or key matches one of these patterns (wildcards allowed).
        An empty list means all profiles.

    .PARAMETER ExcludeProfiles
        Never sync profiles whose display name or key matches one of these patterns (wildcards allowed).

    .PARAMETER ArchiveRetention
        Number of versions kept per profile and category in the archive of the sync folder.

    .PARAMETER CloseBackgroundEdge
        Allow stopping windowless (Startup Boost) Edge processes so incoming changes can be applied.

    .PARAMETER RemoveDeletedProfiles
        When a profile was removed on another machine with Remove-EdgeProfile, also remove it on this
        machine (to the Recycle Bin, only while Edge is fully closed). Default: $false.

    .PARAMETER IntervalMinutes
        Repetition interval of the scheduled sync task. Re-run Register-EdgeProfileSyncTask -Force
        to apply a new interval to an existing task.

    .PARAMETER PassThru
        Return the resulting configuration.

    .EXAMPLE
        Set-EdgeProfileSyncConfig -SyncRoot "$env:OneDrive\EdgeProfileSync"

        Uses a folder in the personal OneDrive as the sync folder.

    .EXAMPLE
        Set-EdgeProfileSyncConfig -ExcludeProfiles 'Work*' -Categories Bookmarks, Settings, Collections -PassThru

        Syncs only bookmarks, settings and collections, skips every profile whose name starts with "Work"
        and shows the resulting configuration.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$SyncRoot,

        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Channels,

        [ValidateNotNullOrEmpty()]
        [string[]]$Categories,

        [AllowEmptyCollection()]
        [string[]]$IncludeProfiles,

        [AllowEmptyCollection()]
        [string[]]$ExcludeProfiles,

        [ValidateRange(1, 1000)]
        [int]$ArchiveRetention,

        [bool]$CloseBackgroundEdge,

        [bool]$RemoveDeletedProfiles,

        [ValidateRange(5, 1440)]
        [int]$IntervalMinutes,

        [switch]$PassThru
    )

    $path = Get-EdgeSyncConfigPath
    $knownKeys = @((Get-EdgeSyncDefaultConfig).Keys)

    # Start from what is in the file (known keys only), so unset values keep following the defaults.
    $newConfig = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $existing = Read-EdgeJsonFile -Path $path
            if ($existing -is [System.Collections.IDictionary]) {
                foreach ($key in $knownKeys) {
                    $fileKey = @($existing.Keys | Where-Object { $_ -ieq $key }) | Select-Object -First 1
                    if ($null -ne $fileKey) { $newConfig[$key] = $existing[$fileKey] }
                }
            }
        }
        catch {
            Write-Warning "Existing configuration file '$path' could not be read and will be replaced: $($_.Exception.Message)"
        }
    }

    if ($PSBoundParameters.ContainsKey('SyncRoot')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($SyncRoot)
        $fullPath = [System.IO.Path]::GetFullPath($expanded, (Get-Location -PSProvider FileSystem).ProviderPath)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            if (Test-Path -LiteralPath $fullPath) {
                throw "SyncRoot '$fullPath' exists but is not a folder."
            }
            if ($PSCmdlet.ShouldProcess($fullPath, 'Create sync folder')) {
                try {
                    $null = New-Item -Path $fullPath -ItemType Directory -Force -ErrorAction Stop
                }
                catch {
                    throw "SyncRoot '$fullPath' cannot be created: $($_.Exception.Message)"
                }
            }
        }
        $newConfig['SyncRoot'] = $fullPath
    }

    if ($PSBoundParameters.ContainsKey('Channels')) {
        $newConfig['Channels'] = @($Channels | Select-Object -Unique)
    }

    if ($PSBoundParameters.ContainsKey('Categories')) {
        $validNames = @(Get-EdgeDataCategoryName)
        $normalized = foreach ($category in $Categories) {
            $match = $validNames | Where-Object { $_ -ieq $category } | Select-Object -First 1
            if (-not $match) {
                throw "Unknown category '$category'. Valid categories: $($validNames -join ', ')."
            }
            $match
        }
        $newConfig['Categories'] = @($normalized | Select-Object -Unique)
    }

    if ($PSBoundParameters.ContainsKey('IncludeProfiles')) {
        $newConfig['IncludeProfiles'] = @($IncludeProfiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($PSBoundParameters.ContainsKey('ExcludeProfiles')) {
        $newConfig['ExcludeProfiles'] = @($ExcludeProfiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($PSBoundParameters.ContainsKey('ArchiveRetention')) { $newConfig['ArchiveRetention'] = $ArchiveRetention }
    if ($PSBoundParameters.ContainsKey('CloseBackgroundEdge')) { $newConfig['CloseBackgroundEdge'] = $CloseBackgroundEdge }
    if ($PSBoundParameters.ContainsKey('RemoveDeletedProfiles')) { $newConfig['RemoveDeletedProfiles'] = $RemoveDeletedProfiles }
    if ($PSBoundParameters.ContainsKey('IntervalMinutes')) { $newConfig['IntervalMinutes'] = $IntervalMinutes }

    if ($PSCmdlet.ShouldProcess($path, 'Write EdgeProfileSync configuration')) {
        Write-EdgeJsonFile -Path $path -InputObject $newConfig
    }

    if ($PassThru) {
        Get-EdgeProfileSyncConfig
    }
}
