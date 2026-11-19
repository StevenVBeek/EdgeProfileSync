function Backup-EdgeProfiles {
    <#
    .SYNOPSIS
        Creates a fast backup (zip or folder) of the current user's Microsoft Edge profiles.

    .DESCRIPTION
        Backs up only the selected data categories of each profile (bookmarks, settings, history,
        collections, ... see the module README). Files are read in place and written into the zip by
        several reader threads (compression level Fastest); with -Format Folder they are copied with robocopy.
        Caches are never touched or deleted. Progress is shown per profile, with sizes, speed and ETA.

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

    .PARAMETER Format
        Zip (default): one zip archive per channel, Edge<Channel>-<yyyyMMdd-HHmmss>.zip.
        Folder: a plain folder per channel, Edge<Channel>-<yyyyMMdd-HHmmss>, copied with robocopy. Much faster
        for large backups (for example -Category All with extension binaries: tens of thousands of files, which
        real-time antivirus scans one by one when they are zipped). With -AddDate $false the same folder
        Edge<Channel> is updated every time and only changed files are copied. Restore-EdgeProfiles accepts both.

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

    .EXAMPLE
        Backup-EdgeProfiles -Category All -Format Folder -AddDate $false -Destination D:\EdgeBackup

        Keeps one complete, incrementally updated folder backup (including extension binaries) in
        D:\EdgeBackup\EdgeStable. Repeated runs only copy what changed.
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

        [ValidateSet('Zip', 'Folder')]
        [string]$Format = 'Zip',

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

        $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $baseName = $AddDate ? "Edge$ch-$timestamp" : "Edge$ch"
        $targetPath = Join-Path $Destination ($Format -eq 'Zip' ? "$baseName.zip" : $baseName)
        $targetKind = $Format -eq 'Zip' ? 'zip archive' : ($AddDate ? 'folder' : 'folder, incremental: only changes are copied')
        $categoryText = $Full ? 'full User Data, without caches' : "categories: $(@($categories | ForEach-Object { $_.Name }) -join ', ')"

        Write-EdgeBox -Title "Backup - Edge $ch" -Rows ([ordered]@{
                'Source'     = $info.UserDataPath
                'Target'     = $targetPath
                'Format'     = $targetKind
                'Profiles'   = "$($profiles.Count)$($ProfileName ? " (filter: $($ProfileName -join ', '))" : '')"
                'Categories' = $Full ? 'full User Data, without caches' : "$(@($categories | ForEach-Object { $_.Name }) -join ', ')"
                'Edge'       = $edgeRunning ? "running ($($state.ProcessCount) processes) - databases are copied as consistent snapshots" : 'not running'
                'Started'    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            })

        # Folder format: copy straight into the target folder. Zip format: a work folder holds only database
        # snapshots and generated files (or the staging copy of -Full); everything else is read in place.
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "EdgeProfileSync-backup-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
        $stageRoot = $Format -eq 'Folder' ? $targetPath : $work
        $null = New-Item -ItemType Directory -Path $work -Force
        $null = New-Item -ItemType Directory -Path $stageRoot -Force
        $progress = $null
        $tmpZip = $null
        $skipped = @()
        [long]$rawSize = 0
        try {
            $channelStage = Join-Path $stageRoot $ch
            $manifestProfiles = [System.Collections.Generic.List[object]]::new()
            $zipItems = [System.Collections.Generic.List[object]]::new()

            if ($Full) {
                # ---------------------------------------------------------------- full User Data
                $excludeDirs = [System.Collections.Generic.List[string]]::new()
                $excludeDirs.AddRange([string[]]$script:EdgeFullBackupExcludeDirs)
                if ($ProfileName) {
                    # Exclude the folders of profiles that were not selected.
                    $selectedDirs = @($profiles | ForEach-Object { $_.Directory })
                    foreach ($p in @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $UserDataRoot)) {
                        if ($p.Directory -notin $selectedDirs) { $excludeDirs.Add($p.Path) }
                    }
                }
                $progress = New-EdgeProgress -Activity "Backing up Edge $ch (full)" -Total ($profiles.Count + 1) -Unit Steps
                Update-EdgeProgress -Progress $progress -Status 'Copying User Data without caches (robocopy)' -Force
                Write-EdgeNote 'Copying User Data without caches (robocopy)...' -Level Info
                $roboSw = [System.Diagnostics.Stopwatch]::StartNew()
                $userDataStage = Join-Path $channelStage 'UserData'
                Invoke-EdgeRobocopy -Source $info.UserDataPath -Destination $userDataStage `
                    -ExcludeDirectory $excludeDirs -ExcludeFile $script:EdgeFullBackupExcludeFiles
                Write-EdgeNote ('Copied {0} in {1}; taking database snapshots...' -f (Format-EdgeSize (Get-EdgePathSize -Path $userDataStage)), (Format-EdgeDuration $roboSw.Elapsed))
                $pi = 0
                foreach ($p in $profiles) {
                    $pi++
                    Update-EdgeProgress -Progress $progress -Done $pi -Status "Database snapshots: profile $pi/$($profiles.Count) '$($p.Name)'"
                    # Re-copy the known SQLite databases as consistent snapshots (Edge may be running).
                    foreach ($cat in @(Get-EdgeDataCategory | Where-Object Sqlite)) {
                        foreach ($f in $cat.Files) {
                            $src = Join-Path $p.Path $f
                            if (Test-Path -LiteralPath $src -PathType Leaf) {
                                try { Copy-EdgeSqliteSnapshot -Source $src -Destination (Join-Path $userDataStage "$($p.Directory)\$f") }
                                catch { Write-EdgeSyncLog -Message "Snapshot of '$src' failed: $($_.Exception.Message)" -Level Warning }
                            }
                        }
                    }
                    $manifestProfiles.Add([ordered]@{
                            Name = $p.Name; Key = $p.Key; Directory = $p.Directory; InfoCache = $p.InfoCache; Categories = @()
                        })
                }
                Complete-EdgeProgress -Progress $progress
                $progress = $null
                if ($Format -eq 'Zip') {
                    foreach ($f in @(Get-EdgeDirectoryFile -Path $userDataStage)) {
                        $zipItems.Add([pscustomobject]@{
                                Source = $f.FullName
                                Entry  = ([System.IO.Path]::GetRelativePath($work, $f.FullName)).Replace('\', '/')
                                Bytes  = $f.Length
                            })
                    }
                }
            }
            else {
                # ---------------------------------------------------------------- scan
                $scan = New-EdgeProgress -Activity "Backing up Edge $ch - scanning" -Total $profiles.Count -Unit Steps
                $plan = [System.Collections.Generic.List[object]]::new()
                $pi = 0
                foreach ($p in $profiles) {
                    $pi++
                    Update-EdgeProgress -Progress $scan -Done ($pi - 1) -Status "Measuring profile $pi/$($profiles.Count) '$($p.Name)'"
                    $sizes = [ordered]@{}
                    foreach ($cat in $categories) { $sizes[$cat.Name] = Get-EdgeCategorySize -ProfilePath $p.Path -Category $cat }
                    $plan.Add([pscustomobject]@{ Profile = $p; Sizes = $sizes; Bytes = [long]($sizes.Values | Measure-Object -Sum).Sum })
                }
                Complete-EdgeProgress -Progress $scan
                [long]$planned = ($plan | Measure-Object -Property Bytes -Sum).Sum
                $largest = (@($plan | Sort-Object Bytes -Descending | Select-Object -First 3) | ForEach-Object { "$($_.Profile.Name) ($(Format-EdgeSize $_.Bytes))" }) -join ', '
                $bigCats = foreach ($cat in $categories) {
                    [long]$catTotal = ($plan | ForEach-Object { $_.Sizes[$cat.Name] } | Measure-Object -Sum).Sum
                    if ($catTotal -ge 100MB) { "$($cat.Name) $(Format-EdgeSize $catTotal)" }
                }
                Write-EdgeNote ''
                Write-EdgeNote ('To back up : {0} in {1} profile(s)' -f (Format-EdgeSize $planned), $profiles.Count) -Level Info
                Write-EdgeNote ('Largest    : {0}' -f $largest)
                if ($bigCats) { Write-EdgeNote ('Large data : {0}' -f ($bigCats -join ', ')) }

                $numWidth = [Math]::Max(3, "$($profiles.Count)".Length)
                $columns = @(
                    @{ Name = '#'; Width = $numWidth; Align = 'Right' }
                    @{ Name = 'Profile'; Width = 28 }
                    @{ Name = 'Folder'; Width = 11 }
                    @{ Name = 'Categories'; Width = 10; Align = 'Right' }
                )
                if ($Format -eq 'Zip') { $columns += @{ Name = 'Files'; Width = 7; Align = 'Right' } }
                $columns += @(
                    @{ Name = 'Size'; Width = 10; Align = 'Right' }
                    @{ Name = 'Time'; Width = 8; Align = 'Right' }
                    @{ Name = 'Note'; Width = 0 }
                )
                $table = New-EdgeTable -Columns $columns
                Write-EdgeTableHeader -Table $table
                [long]$totalFiles = 0
                $totalCats = 0

                # ---------------------------------------------------------------- per profile
                $activity = $Format -eq 'Zip' ? "Backing up Edge $ch - collecting files" : "Backing up Edge $ch"
                $progress = New-EdgeProgress -Activity $activity -Total $planned
                $pi = 0
                foreach ($item in $plan) {
                    $p = $item.Profile
                    $pi++
                    $profileSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $done = [System.Collections.Generic.List[string]]::new()
                    $failed = [System.Collections.Generic.List[string]]::new()
                    [long]$profileFiles = 0
                    foreach ($cat in $categories) {
                        $catBytes = [long]$item.Sizes[$cat.Name]
                        Update-EdgeProgress -Progress $progress -Status "Profile $pi/$($profiles.Count) '$($p.Name)'" `
                            -CurrentOperation ('{0} ({1})' -f $cat.Name, (Format-EdgeSize $catBytes)) -Force
                        try {
                            if ($Format -eq 'Zip') {
                                $catItems = @(Get-EdgeCategoryZipItem -ProfilePath $p.Path -Category $cat -EntryPrefix "$ch/$($p.Key)/$($cat.Name)" -WorkDir $work)
                                if ($catItems.Count) {
                                    $zipItems.AddRange([object[]]$catItems)
                                    $done.Add($cat.Name)
                                    $profileFiles += $catItems.Count
                                }
                            }
                            elseif (Copy-EdgeCategoryToStage -ProfilePath $p.Path -Category $cat -StagePath (Join-Path $channelStage (Join-Path $p.Key $cat.Name))) {
                                $done.Add($cat.Name)
                            }
                        }
                        catch {
                            $failed.Add($cat.Name)
                            Write-EdgeSyncLog -Message "Backup Edge $ch '$($p.Key)' $($cat.Name) failed: $($_.Exception.Message)" -Level Warning
                        }
                        Update-EdgeProgress -Progress $progress -Add $catBytes
                    }
                    $totalFiles += $profileFiles
                    $totalCats += $done.Count
                    $row = @($pi, $p.Name, $p.Directory, "$($done.Count)/$($categories.Count)")
                    if ($Format -eq 'Zip') { $row += ('{0:N0}' -f $profileFiles) }
                    $row += @((Format-EdgeSize $item.Bytes), (Format-EdgeDuration $profileSw.Elapsed), ($failed.Count ? "failed: $($failed -join ', ')" : ''))
                    Write-EdgeTableRow -Table $table -Values $row -Level ($failed.Count ? 'Warning' : 'Info')
                    $manifestProfiles.Add([ordered]@{
                            Name = $p.Name; Key = $p.Key; Directory = $p.Directory; InfoCache = $p.InfoCache; Categories = @($done)
                        })
                }
                Complete-EdgeProgress -Progress $progress
                $progress = $null
                Write-EdgeTableRule -Table $table
                $totalRow = @('', 'Total', '', "$totalCats")
                if ($Format -eq 'Zip') { $totalRow += ('{0:N0}' -f $totalFiles) }
                $totalRow += @((Format-EdgeSize $planned), (Format-EdgeDuration $sw.Elapsed), '')
                Write-EdgeTableRow -Table $table -Values $totalRow -Level Info
            }

            # ---------------------------------------------------------------- registry + manifest
            $registryEntry = $null
            if (-not $UserDataRoot -and $info.RegistryKey) {
                $regFile = Join-Path $stageRoot 'registry\PreferenceMACs.reg'
                if (Export-EdgeRegistryKey -Key $info.RegistryKey -Path $regFile) {
                    $registryEntry = 'registry/PreferenceMACs.reg'
                    if ($Format -eq 'Zip') {
                        $zipItems.Add([pscustomobject]@{ Source = $regFile; Entry = $registryEntry; Bytes = (Get-Item -LiteralPath $regFile).Length })
                    }
                }
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
            $manifestFile = Join-Path $stageRoot 'backup-manifest.json'
            Write-EdgeJsonFile -Path $manifestFile -InputObject $manifest

            if ($Format -eq 'Zip') {
                $zipItems.Add([pscustomobject]@{ Source = $manifestFile; Entry = 'backup-manifest.json'; Bytes = (Get-Item -LiteralPath $manifestFile).Length })
                $rawSize = ($zipItems | Measure-Object -Property Bytes -Sum).Sum
                $zipName = Split-Path $targetPath -Leaf
                Write-EdgeNote ''
                if ($zipItems.Count -ge 10000) {
                    Write-EdgeNote ('{0:N0} files to compress. With real-time antivirus every file is scanned when it is opened, so this can take minutes; -Format Folder (robocopy) is much faster for backups this size.' -f $zipItems.Count) -Level Warning
                }
                $tmpZip = "$targetPath.tmp"
                if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force }
                Write-EdgeNote ('Compressing {0:N0} file(s), {1}, into {2}...' -f $zipItems.Count, (Format-EdgeSize $rawSize), $zipName) -Level Info
                $zipSw = [System.Diagnostics.Stopwatch]::StartNew()
                $skipped = @(Write-EdgeZipFromList -Items $zipItems.ToArray() -ZipPath $tmpZip -Activity "Backing up Edge $ch - compressing $zipName" -ProgressId 1)
                Write-EdgeNote ('Compressed in {0}' -f (Format-EdgeDuration $zipSw.Elapsed))
                foreach ($s in $skipped) {
                    Write-EdgeSyncLog -Message "Backup: skipped $($s.Entry) - $($s.Reason)" -Level Info
                    Write-EdgeNote "Skipped (could not be read): $($s.Entry) - $($s.Reason)" -Level Warning
                }
                Move-Item -LiteralPath $tmpZip -Destination $targetPath -Force
            }
            else {
                $rawSize = Get-EdgePathSize -Path $targetPath
            }
        }
        catch {
            # A failure here leaves no usable backup for this channel: report it and go on with the next one.
            Write-EdgeStatus "Backup of Edge $ch FAILED: $($_.Exception.Message)" -Level Warning -Log
            if ($tmpZip -and (Test-Path -LiteralPath $tmpZip)) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction Ignore }
            Write-Error -ErrorRecord $_ -ErrorAction Continue
            continue
        }
        finally {
            if ($progress) { Complete-EdgeProgress -Progress $progress }
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Ignore
        }

        # ---------------------------------------------------------------- retention
        if ($Retention -gt 0) {
            $isZip = $Format -eq 'Zip'
            $pattern = $isZip ? "^Edge$ch-\d{8}-\d{6}\.zip$" : "^Edge$ch-\d{8}-\d{6}$"
            Get-ChildItem -LiteralPath $Destination -Filter ($isZip ? "Edge$ch-*.zip" : "Edge$ch-*") -File:$isZip -Directory:(-not $isZip) |
                Where-Object Name -Match $pattern |
                Sort-Object Name -Descending |
                Select-Object -Skip $Retention |
                ForEach-Object {
                    Write-EdgeNote "Retention: removed old backup $($_.Name)"
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force
                }
        }

        $sw.Stop()
        [long]$outBytes = $Format -eq 'Zip' ? (Get-Item -LiteralPath $targetPath).Length : $rawSize
        $summary = 'Edge {0} backup: {1} profile(s), {2:N1} MB data -> {3:N1} MB {4} in {5:N1} s: {6}' -f `
            $ch, $profiles.Count, ($rawSize / 1MB), ($outBytes / 1MB), $Format.ToLowerInvariant(), $sw.Elapsed.TotalSeconds, $targetPath
        Write-EdgeSyncLog -Message $summary -Level Info
        Write-EdgeBox -Title ('Backup finished in {0}' -f (Format-EdgeDuration $sw.Elapsed)) -Level ($skipped.Count ? 'Warning' : 'Success') -Rows ([ordered]@{
                'Profiles'                          = $profiles.Count
                'Data'                              = (Format-EdgeSize $rawSize) + ($Format -eq 'Zip' ? " (zip: $(Format-EdgeSize $outBytes))" : '')
                'Skipped'                           = $skipped.Count ? "$($skipped.Count) file(s) that could not be read (listed above)" : $null
                ($Format -eq 'Zip' ? 'File' : 'Folder') = $targetPath
                'Restore with'                      = "Restore-EdgeProfiles -Path '$targetPath'"
            })

        if ($PassThru) {
            [pscustomobject]@{
                Channel      = $ch
                Path         = $targetPath
                Format       = $Format
                Profiles     = $profiles.Count
                Categories   = $Full ? @('Full') : @($categories | ForEach-Object { $_.Name })
                DataBytes    = $rawSize
                ZipBytes     = $Format -eq 'Zip' ? $outBytes : $null
                SkippedFiles = $skipped.Count
                Duration     = $sw.Elapsed
                MachineId    = $machineId
            }
        }
    }
}
