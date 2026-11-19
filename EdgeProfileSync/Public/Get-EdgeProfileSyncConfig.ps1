function Get-EdgeProfileSyncConfig {
    <#
    .SYNOPSIS
        Returns the EdgeProfileSync configuration of the current user on this machine.

    .DESCRIPTION
        Reads "<LocalDataPath>\config.json" (by default %LOCALAPPDATA%\EdgeProfileSync\config.json)
        and merges it over the built-in defaults, so every setting always has a value:

        - SyncRoot            : shared folder for sync (default: OneDrive for Business, else personal
                                OneDrive, joined with "EdgeProfileSync").
        - Channels            : Edge channels to sync (default: Stable).
        - Categories          : data categories to sync (default: all categories marked as default).
        - IncludeProfiles     : profile names/keys to include (wildcards allowed; empty = all).
        - ExcludeProfiles     : profile names/keys to exclude (wildcards allowed).
        - ArchiveRetention    : versions kept per profile/category in the store archive (default 10).
        - CloseBackgroundEdge : allow stopping windowless (Startup Boost) Edge to apply changes (default $true).
        - IntervalMinutes     : repetition interval of the scheduled task (default 30).

        Unknown keys in the file are ignored. A corrupt file produces a warning and the defaults.

    .OUTPUTS
        [pscustomobject] with one property per setting plus ConfigPath.

    .EXAMPLE
        Get-EdgeProfileSyncConfig

        Shows the effective configuration.

    .EXAMPLE
        (Get-EdgeProfileSyncConfig).SyncRoot

        Shows the folder that is used to sync profiles between machines.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $config = Get-EdgeSyncDefaultConfig
    $path = Get-EdgeSyncConfigPath

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $fileConfig = $null
        try {
            $fileConfig = Read-EdgeJsonFile -Path $path
        }
        catch {
            Write-Warning "Could not read configuration file '$path', using defaults: $($_.Exception.Message)"
        }

        if ($fileConfig -is [System.Collections.IDictionary]) {
            foreach ($key in @($config.Keys)) {
                # Case-insensitive key lookup (hashtables from JSON may be case-sensitive).
                $fileKey = @($fileConfig.Keys | Where-Object { $_ -ieq $key }) | Select-Object -First 1
                if ($null -eq $fileKey) { continue }
                $value = $fileConfig[$fileKey]
                switch ($key) {
                    { $_ -in 'Channels', 'Categories', 'IncludeProfiles', 'ExcludeProfiles' } {
                        $config[$key] = [string[]]@($value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                    }
                    { $_ -in 'ArchiveRetention', 'IntervalMinutes' } {
                        if ($null -ne $value) { $config[$key] = [int]$value }
                    }
                    { $_ -in 'CloseBackgroundEdge', 'RemoveDeletedProfiles' } {
                        # JSON booleans arrive as [bool]; tolerate hand-edited "true"/"false" strings too.
                        if ($value -is [bool]) { $config[$key] = $value }
                        elseif ($null -ne $value) { $config[$key] = [string]$value -in 'true', '1', 'yes' }
                    }
                    default {
                        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $config[$key] = [string]$value }
                    }
                }
            }
        }
        elseif ($null -ne $fileConfig) {
            Write-Warning "Configuration file '$path' does not contain a JSON object, using defaults."
        }
    }

    $config['ConfigPath'] = $path
    [pscustomobject]$config
}
