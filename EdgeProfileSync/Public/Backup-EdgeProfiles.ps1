function Backup-EdgeProfiles {
    <#
    .SYNOPSIS
        Creates a fast zip backup of the current user's Microsoft Edge profiles.

    .DESCRIPTION
        Copies only the selected data categories of each profile (bookmarks, settings, history,
        collections, ... see Get-EdgeProfile / the module README) into a staging folder and zips it
        with .NET ZipFile (compression level Fastest). Caches are never touched or deleted.

        Archive layout:
            backup-manifest.json                     module version, machine id, channel, profiles
            <Channel>\<ProfileKey>\<Category>\...    the profile files per category
            registry\PreferenceMACs.reg              HKCU ...\Edge\PreferenceMACs export
        With -Full the archive contains <Channel>\UserData\... instead (the whole User Data folder
        minus caches, crash dumps, ML models and other rebuildable data).

        Edge may stay open: SQLite databases (History, Favicons, Collections, Autofill) are copied as
        consistent snapshots (Copy-EdgeSqliteSnapshot). -CloseEdge is optional.

        One zip is created per channel: Edge<Channel>-<yyyyMMdd-HHmmss>.zip.

    .PARAMETER Destination
        Folder for the zip files. Defaults to "<SyncRoot>\backups\<MachineId>" (SyncRoot from
        Get-EdgeProfileSyncConfig, by default OneDrive\EdgeProfileSync).

    .PARAMETER Channel
        Edge channel(s) to back up: Stable (default), Beta, Dev, Canary.

    .PARAMETER Profile
        Profiles to include, matched against display name, key or folder name (wildcards allowed).
        Default: all profiles.

    .PARAMETER Category
        Data categories to include. Default: the default categories. 'All' includes every category.

    .PARAMETER Full
        Back up the whole User Data folder (all profiles, Local State, passwords, cookies, ...) minus
        caches and other rebuildable data, like EDGEProfiles 1.x did. Only useful on the same machine
        and user account. Ignores -Category.

    .PARAMETER CloseEdge
        Stop Edge of the channel before the backup (open windows are closed!).

    .PARAMETER AddDate
        Add a timestamp to the zip name (default $true). With $false an existing zip is overwritten.

    .PARAMETER Retention
        Keep only the N newest timestamped zips per channel in the destination. 0 (default) keeps all.

    .PARAMETER PassThru
        Return an object per created archive.

    .PARAMETER FoldersToClean
        Accepted for compatibility with EDGEProfiles 1.x and ignored: caches are never deleted
        from the live profile (and are never included in a backup).

    .EXAMPLE
        Backup-EdgeProfiles

        Backs up the default categories of all Stable profiles to OneDrive\EdgeProfileSync\backups\<machine>.

    .EXAMPLE
        Backup-EdgeProfiles -Destination D:\EdgeBackup -Channel Stable, Beta -Category All -Retention 5

    .EXAMPLE
        Backup-EdgeProfiles -Profile 'Work*' -Category Bookmarks -CloseEdge -PassThru
    #>
    [CmdletBinding()]
    param(
        [string]$Destination,

        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string[]]$Channel = @('Stable'),

        [Alias('Profile')]
        [SupportsWildcards()]
        [string[]]$ProfileName,

        [string[]]$Category,

        [switch]$Full,

        [switch]$CloseEdge,

        [bool]$AddDate = $true,

        [ValidateRange(0, 10000)]
        [int]$Retention = 0,

        [switch]$PassThru,

        [Parameter(DontShow)]
        [string[]]$FoldersToClean,

        # Overrides the User Data folder (tests). Also skips the registry export.
        [Parameter(DontShow)]
        [string]$UserDataRoot
    )

    if ($PSBoundParameters.ContainsKey('FoldersToClean')) {
        Write-Warning '-FoldersToClean is ignored: caches are never deleted and are excluded from backups automatically.'
    }

    $categories = $Full ? @() : @(Resolve-EdgeBackupCategory -Category $Category)
    $machineId = Get-EdgeSyncMachineId

    if (-not $Destination) {
        $Destination = Get-EdgeDefaultBackupDestination -MachineId $machineId
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force
    }
    $Destination = (Resolve-Path -LiteralPath $Destination).ProviderPath

    $moduleVersion = $ExecutionContext.SessionState.Module ? [string]$ExecutionContext.SessionState.Module.Version : '0.0.0'

    foreach ($ch in $Channel) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $info = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
        if (-not $info.Installed) {
            Write-Warning "Edge $ch has no User Data folder ($($info.UserDataPath)); skipped."
            continue
        }

        # --- Edge running?
        $state = Get-EdgeProcessState -Channel $ch
        $edgeRunning = [bool]$state.Running
        if ($edgeRunning -and $CloseEdge) {
            Write-EdgeSyncLog -Message "Stopping Edge $ch for backup." -Level Info
            if (Stop-EdgeProcess -Channel $ch) { $edgeRunning = $false }
            else { Write-Warning "Edge $ch could not be stopped; continuing with a live copy." }
        }

        # --- profiles
        $profiles = @(Select-EdgeProfileByFilter -InputObject @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $UserDataRoot) -Filter $ProfileName)
        if (-not $profiles) {
            Write-Warning "Edge ${ch}: no profiles matched$($ProfileName ? " '$($ProfileName -join "', '")'" : '')."
            continue
        }

        $staging = Join-Path ([System.IO.Path]::GetTempPath()) "EdgeProfileSync-backup-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
        $null = New-Item -ItemType Directory -Path $staging -Force
        try {
            $channelStage = Join-Path $staging $ch
            $manifestProfiles = [System.Collections.Generic.List[object]]::new()

            if ($Full) {
                $excludeDirs = [System.Collections.Generic.List[string]]::new()
                $excludeDirs.AddRange([string[]]$script:EdgeFullBackupExcludeDirs)
                if ($ProfileName) {
                    # Exclude the folders of profiles that were not selected.
                    $selectedDirs = @($profiles | ForEach-Object { $_.Directory })
                    foreach ($p in @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $UserDataRoot)) {
                        if ($p.Directory -notin $selectedDirs) { $excludeDirs.Add($p.Path) }
                    }
                }
                Invoke-EdgeRobocopy -Source $info.UserDataPath -Destination (Join-Path $channelStage 'UserData') `
                    -ExcludeDirectory $excludeDirs -ExcludeFile $script:EdgeFullBackupExcludeFiles
                foreach ($p in $profiles) {
                    # Re-copy the known SQLite databases as consistent snapshots (Edge may be running).
                    foreach ($cat in @(Get-EdgeDataCategory | Where-Object Sqlite)) {
                        foreach ($f in $cat.Files) {
                            $src = Join-Path $p.Path $f
                            if (Test-Path -LiteralPath $src -PathType Leaf) {
                                try { Copy-EdgeSqliteSnapshot -Source $src -Destination (Join-Path $channelStage "UserData\$($p.Directory)\$f") }
                                catch { Write-EdgeSyncLog -Message "Snapshot of '$src' failed: $($_.Exception.Message)" -Level Warning }
                            }
                        }
                    }
                    $manifestProfiles.Add([ordered]@{
                            Name = $p.Name; Key = $p.Key; Directory = $p.Directory; InfoCache = $p.InfoCache; Categories = @()
                        })
                }
            }
            else {
                foreach ($p in $profiles) {
                    $done = [System.Collections.Generic.List[string]]::new()
                    foreach ($cat in $categories) {
                        $catStage = Join-Path $channelStage (Join-Path $p.Key $cat.Name)
                        try {
                            if (Copy-EdgeCategoryToStage -ProfilePath $p.Path -Category $cat -StagePath $catStage) {
                                $done.Add($cat.Name)
                            }
                        }
                        catch {
                            Write-EdgeSyncLog -Message "Backup Edge $ch '$($p.Key)' $($cat.Name) failed: $($_.Exception.Message)" -Level Warning
                        }
                    }
                    $manifestProfiles.Add([ordered]@{
                            Name = $p.Name; Key = $p.Key; Directory = $p.Directory; InfoCache = $p.InfoCache; Categories = @($done)
                        })
                }
            }

            # --- registry (PreferenceMACs); skipped when a test User Data root is used
            $registryEntry = $null
            if (-not $UserDataRoot -and $info.RegistryKey) {
                $regFile = Join-Path $staging 'registry\PreferenceMACs.reg'
                if (Export-EdgeRegistryKey -Key $info.RegistryKey -Path $regFile) { $registryEntry = 'registry/PreferenceMACs.reg' }
            }

            $manifest = [ordered]@{
                FormatVersion  = 2
                ModuleVersion  = $moduleVersion
                MachineId      = $machineId
                ComputerName   = $env:COMPUTERNAME
                CreatedUtc     = [datetime]::UtcNow.ToString('o')
                Channel        = $ch
                Full           = [bool]$Full
                EdgeWasRunning = $edgeRunning
                Categories     = @($categories | ForEach-Object { $_.Name })
                Registry       = $registryEntry
                Profiles       = @($manifestProfiles)
            }
            Write-EdgeJsonFile -Path (Join-Path $staging 'backup-manifest.json') -InputObject $manifest

            [long]$rawSize = (Get-ChildItem -LiteralPath $staging -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum

            # --- zip
            $zipName = $AddDate ? "Edge$ch-$((Get-Date).ToString('yyyyMMdd-HHmmss')).zip" : "Edge$ch.zip"
            $zipPath = Join-Path $Destination $zipName
            $tmpZip = "$zipPath.tmp"
            if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force }
            [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $tmpZip, [System.IO.Compression.CompressionLevel]::Fastest, $false)
            Move-Item -LiteralPath $tmpZip -Destination $zipPath -Force
        }
        finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore
        }

        # --- retention
        if ($Retention -gt 0) {
            $pattern = "^Edge$ch-\d{8}-\d{6}\.zip$"
            Get-ChildItem -LiteralPath $Destination -Filter "Edge$ch-*.zip" -File |
                Where-Object Name -Match $pattern |
                Sort-Object Name -Descending |
                Select-Object -Skip $Retention |
                ForEach-Object {
                    Write-Verbose "Retention: removing $($_.FullName)"
                    Remove-Item -LiteralPath $_.FullName -Force
                }
        }

        $sw.Stop()
        $zipItem = Get-Item -LiteralPath $zipPath
        $summary = 'Edge {0} backup: {1} profile(s), {2:N1} MB data -> {3:N1} MB zip in {4:N1} s: {5}' -f `
            $ch, $profiles.Count, ($rawSize / 1MB), ($zipItem.Length / 1MB), $sw.Elapsed.TotalSeconds, $zipPath
        Write-Host $summary
        Write-EdgeSyncLog -Message $summary -Level Info

        if ($PassThru) {
            [pscustomobject]@{
                Channel    = $ch
                Path       = $zipPath
                Profiles   = $profiles.Count
                Categories = $Full ? @('Full') : @($categories | ForEach-Object { $_.Name })
                DataBytes  = $rawSize
                ZipBytes   = $zipItem.Length
                Duration   = $sw.Elapsed
                MachineId  = $machineId
            }
        }
    }
}
