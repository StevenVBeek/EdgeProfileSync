function Restore-EdgeProfiles {
    <#
    .SYNOPSIS
        Restores Microsoft Edge profiles from a zip created by Backup-EdgeProfiles.

    .DESCRIPTION
        Restores the categories in the backup into the matching local profiles. Backup profiles are
        matched to local profiles by Key (derived from the display name); missing profiles are created.

        -ExistingDataAction:
          Merge  (default) Per category, the existing files are moved aside into
                 "<User Data>\EdgeProfileSync-replaced\<timestamp>\<profile>\<category>\" and then
                 replaced by the backup. Profiles and categories that are not in the backup are untouched.
          Rename The whole User Data folder is renamed to "User Data-<timestamp>" and the backup is
                 restored into a fresh User Data folder (only the restored profiles exist afterwards).
          Remove As Rename, but the old User Data folder is deleted after a successful restore
                 (asks for confirmation unless -Force).

        Machine-bound categories (SecurePreferences, Extensions) are only restored when the backup was
        made on this machine. Extensions: on the same machine with Extensions + SecurePreferences in the
        backup they come back completely. Otherwise the extension data (ExtensionData) is restored and
        the missing extensions are listed with their store links and remembered as "pending";
        Install-EdgeProfileExtension opens the store pages so they can be installed with one click.

        Zips made by EDGEProfiles 1.x (no backup-manifest.json) are restored the 1.x way: the whole
        User Data folder is replaced (Rename/Remove; Merge is treated as Rename) and -REGSource is imported.

        Edge may stay open for a Merge restore into profiles that are not loaded (no open window);
        loaded profiles and profiles that have to be created are skipped with a warning. Rename/Remove,
        -Full and 1.x backups need Edge closed. -CloseEdge stops Edge first.

    .PARAMETER Path
        The backup: a zip, or a folder made with Backup-EdgeProfiles -Format Folder
        (alias: ZIPSource, as in EDGEProfiles 1.x). A folder backup is read in place and never changed.

    .PARAMETER Channel
        Target Edge channel. Default: the channel the backup was made from (1.x zips: Stable).

    .PARAMETER Profile
        Only restore these backup profiles (display name, key or folder name; wildcards allowed).

    .PARAMETER Category
        Only restore these categories ('All' = everything in the backup). Default: everything in the backup.

    .PARAMETER ExistingDataAction
        Merge (default), Rename or Remove. See the description.

    .PARAMETER CloseEdge
        Stop Edge of the channel if it is running (open windows are closed!).

    .PARAMETER ImportRegistry
        Import the PreferenceMACs registry export from the backup. Only honoured when the backup was
        made on this machine.

    .PARAMETER REGSource
        1.x zips only: the .reg file created next to the zip by EDGEProfiles 1.x; it is imported.

    .PARAMETER Force
        Do not ask for confirmation for -ExistingDataAction Remove.

    .PARAMETER PassThru
        Return one result object per profile and category.

    .EXAMPLE
        Restore-EdgeProfiles -Path .\EdgeStable-20261119-101500.zip -CloseEdge

    .EXAMPLE
        Restore-EdgeProfiles -Path .\EdgeStable-20261119-101500.zip -Profile Work -Category Bookmarks -WhatIf

    .EXAMPLE
        Restore-EdgeProfiles -ZIPSource .\EdgeStable-UserData30July2021-me.zip -REGSource .\EdgeStable-ProfilesRegistry30July2021-me.reg -ExistingDataAction Rename
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Alias('ZIPSource')]
        [string]$Path,

        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel,

        [Alias('Profile')]
        [SupportsWildcards()]
        [string[]]$ProfileName,

        [string[]]$Category,

        [ValidateSet('Merge', 'Rename', 'Remove')]
        [string]$ExistingDataAction = 'Merge',

        [switch]$CloseEdge,

        [switch]$ImportRegistry,

        [string]$REGSource,

        [switch]$Force,

        [switch]$PassThru,

        # Overrides the User Data folder (tests). Registry import is never done with this set.
        [Parameter(DontShow)]
        [string]$UserDataRoot
    )
    $zipPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $results = [System.Collections.Generic.List[object]]::new()
    $addResult = {
        param($ch, $prof, $dir, $cat, $action, $reason)
        $results.Add([pscustomobject]@{ Channel = $ch; Profile = $prof; Directory = $dir; Category = $cat; Action = $action; Reason = $reason })
    }

    # A backup is either a zip or a folder made with Backup-EdgeProfiles -Format Folder.
    $isFolder = Test-Path -LiteralPath $zipPath -PathType Container
    $zipSize = Get-EdgePathSize -Path $zipPath
    $backupText = '{0} ({1}, {2})' -f $zipPath, ($isFolder ? 'folder' : 'zip'), (Format-EdgeSize $zipSize)

    $staging = $isFolder ? $zipPath : (Join-Path ([System.IO.Path]::GetTempPath()) "EdgeProfileSync-restore-$([guid]::NewGuid().ToString('N').Substring(0, 12))")
    $progress = $null
    try {
        if ($isFolder) {
            $isV2 = Test-Path -LiteralPath (Join-Path $staging 'backup-manifest.json') -PathType Leaf
            if (-not $isV2) { throw "'$zipPath' is a folder but contains no backup-manifest.json (not made by Backup-EdgeProfiles -Format Folder)." }
        }
        else {
            Write-Verbose "Extracting '$zipPath' to '$staging'"
            Write-EdgeNote ''
            Write-EdgeNote "Extracting $(Split-Path $zipPath -Leaf) to a temporary folder..." -Level Info
            $extract = Expand-EdgeZipToDirectory -ZipPath $zipPath -Destination $staging -Activity "Extracting $(Split-Path $zipPath -Leaf)"
            $isV2 = $extract.IsV2
            Write-EdgeNote ('Extracted {0:N0} file(s), {1}, in {2}' -f $extract.Files, (Format-EdgeSize $extract.Bytes), (Format-EdgeDuration $extract.Duration))
        }

        # ------------------------------------------------------------------ 1.x zip
        if (-not $isV2) {
            $ch = $Channel ? $Channel : 'Stable'
            $info = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
            $userData = $info.UserDataPath
            Write-EdgeBox -Title "Restore - Edge $ch (EDGEProfiles 1.x backup)" -Rows ([ordered]@{
                    'Backup' = $backupText
                    'Target' = $userData
                    'Action' = "$ExistingDataAction - the whole User Data folder is replaced$($CloseEdge ? ', Edge is closed first' : '')"
                })
            if ($ProfileName -or $Category) { Write-Warning '-Profile and -Category are ignored for 1.x backups.' }
            if ($ExistingDataAction -eq 'Merge') {
                Write-Warning '1.x backups replace the whole User Data folder: -ExistingDataAction Merge is treated as Rename.'
                $ExistingDataAction = 'Rename'
            }
            $src = Join-Path $staging 'User Data'
            if (-not (Test-Path -LiteralPath $src -PathType Container)) { $src = $staging }
            if (-not (Test-Path -LiteralPath (Join-Path $src 'Local State'))) {
                throw "'$zipPath' contains neither backup-manifest.json nor an Edge User Data folder."
            }

            $null = Assert-EdgeRestoreAllowed -Channel $ch -CloseEdge:$CloseEdge -RequireClosed -Cmdlet $PSCmdlet
            $oldUserData = Move-EdgeUserDataAside -UserDataPath $userData -Action $ExistingDataAction -Timestamp $timestamp -Force:$Force -Cmdlet $PSCmdlet
            if ($null -eq $oldUserData -and $ExistingDataAction -ne 'Merge' -and (Test-Path -LiteralPath $userData) -and -not $WhatIfPreference) { return }
            if ($oldUserData) { Write-EdgeNote "Previous User Data renamed to '$oldUserData'." -Level Step }

            if ($PSCmdlet.ShouldProcess($userData, 'Restore User Data from 1.x backup')) {
                $copySw = [System.Diagnostics.Stopwatch]::StartNew()
                Write-EdgeNote ('Copying User Data ({0}) to {1}...' -f (Format-EdgeSize (Get-EdgePathSize -Path $src)), $userData) -Level Step
                Invoke-EdgeRobocopy -Source $src -Destination $userData
                Write-EdgeNote ('User Data copied in {0}.' -f (Format-EdgeDuration $copySw.Elapsed))
                & $addResult $ch '*' '*' 'Legacy' 'Restored' $zipPath
            }
            if ($REGSource) {
                if ($UserDataRoot) { Write-Verbose 'Test User Data root in use; registry import skipped.' }
                elseif (-not (Test-Path -LiteralPath $REGSource -PathType Leaf)) { Write-Warning "Registry file '$REGSource' not found; not imported." }
                elseif ($PSCmdlet.ShouldProcess($REGSource, 'Import registry file')) {
                    Write-EdgeNote "Importing registry file '$REGSource'..." -Level Step
                    Import-EdgeRegistryFile -Path $REGSource
                }
            }
            if ($ExistingDataAction -eq 'Remove' -and $oldUserData -and $PSCmdlet.ShouldProcess($oldUserData, 'Delete previous User Data')) {
                Write-EdgeNote "Deleting previous User Data '$oldUserData'..." -Level Step
                Remove-Item -LiteralPath $oldUserData -Recurse -Force
            }
            $sw.Stop()
            Write-EdgeNote ('Edge {0} restore (1.x backup) completed in {1}.{2}' -f $ch, (Format-EdgeDuration $sw.Elapsed),
                (($oldUserData -and $ExistingDataAction -ne 'Remove') ? " Previous User Data: $oldUserData" : '')) -Level Success
            if ($PassThru) { $results }
            return
        }

        # ------------------------------------------------------------------ 2.x zip
        $manifest = Read-EdgeJsonFile -Path (Join-Path $staging 'backup-manifest.json')
        $srcChannel = [string]$manifest['Channel']
        $ch = $Channel ? $Channel : $srcChannel
        $info = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
        $userData = $info.UserDataPath
        $machineId = Get-EdgeSyncMachineId
        $sameMachine = [string]$manifest['MachineId'] -eq $machineId

        # categories to restore
        $inBackup = @($manifest['Categories'])
        $wanted = if (-not $Category -or $Category -contains 'All') { @(Get-EdgeDataCategory | Where-Object Name -in $inBackup) }
        else { @(Resolve-EdgeBackupCategory -Category $Category | Where-Object Name -in $inBackup) }

        $backupProfiles = @(Select-EdgeProfileByFilter -InputObject @($manifest['Profiles']) -Filter $ProfileName)

        # ---- header
        $created = ''
        if ($manifest['CreatedUtc']) {
            try { $created = ([datetime]::Parse([string]$manifest['CreatedUtc'], [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }
            catch { $created = [string]$manifest['CreatedUtc'] }
        }
        $origin = @($manifest['ComputerName'], $manifest['MachineId']) | Where-Object { $_ } | Select-Object -Unique
        $actionText = switch ($ExistingDataAction) {
            'Merge' { 'Merge - restore into the existing profiles (replaced files are kept aside)' }
            'Rename' { 'Rename - current User Data is renamed aside, then a fresh one is built from the backup' }
            'Remove' { 'Remove - current User Data is deleted after a successful restore' }
        }
        Write-EdgeBox -Title ("Restore - Edge $ch$($WhatIfPreference ? ' (WhatIf: nothing is changed)' : '')") -Rows ([ordered]@{
                'Backup'     = $backupText
                'Created'    = '{0} on {1}{2}' -f ($created ? $created : 'unknown'), ($origin ? ($origin -join ' / ') : 'unknown machine'), ($sameMachine ? ' (this machine)' : ' (another machine)')
                'Target'     = "$userData$($manifest['Full'] ? ' (full User Data backup)' : '')"
                'Profiles'   = $manifest['Full'] ? $null : ('{0} of {1} in the backup' -f $backupProfiles.Count, @($manifest['Profiles']).Count)
                'Categories' = $manifest['Full'] ? $null : ($wanted ? (($wanted | ForEach-Object { $_.Name }) -join ', ') : '(none)')
                'Action'     = "$actionText$($CloseEdge ? '; Edge is closed first' : '')"
                'Started'    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            })
        if (-not $sameMachine) {
            Write-EdgeNote 'Backup from another machine: machine-bound data (SecurePreferences, extension binaries, registry) is not restored;' -Level Warning
            Write-EdgeNote 'extensions are listed for reinstall (Install-EdgeProfileExtension).' -Level Warning
        }

        if (-not $backupProfiles -and -not $manifest['Full']) {
            Write-Warning "No profiles in the backup match$($ProfileName ? " '$($ProfileName -join "', '")'" : '')."
            return
        }

        # Replacing User Data or a full backup needs Edge closed; a Merge only needs the target
        # profiles to be not loaded (checked per profile below).
        $requireClosed = $ExistingDataAction -ne 'Merge' -or [bool]$manifest['Full']
        $edgeRunning = Assert-EdgeRestoreAllowed -Channel $ch -CloseEdge:$CloseEdge -RequireClosed:$requireClosed -Cmdlet $PSCmdlet
        if ($edgeRunning) { Write-EdgeNote "Edge $ch is running: profiles that are open in Edge, and profiles that have to be created, are skipped." -Level Warning }

        $fresh = $ExistingDataAction -ne 'Merge' -or -not (Test-Path -LiteralPath $userData -PathType Container)
        $oldUserData = Move-EdgeUserDataAside -UserDataPath $userData -Action $ExistingDataAction -Timestamp $timestamp -Force:$Force -Cmdlet $PSCmdlet
        if ($null -eq $oldUserData -and $ExistingDataAction -ne 'Merge' -and (Test-Path -LiteralPath $userData) -and -not $WhatIfPreference) { return }
        if ($oldUserData) { Write-EdgeNote "Previous User Data renamed to '$oldUserData'." -Level Info }

        $pendingTotal = 0
        $restoredBytes = [long]0
        $profRestored = 0; $profSkipped = 0; $profFailed = 0

        if ($manifest['Full']) {
            # ---- full User Data backup
            if ($ProfileName -or $Category) { Write-Warning '-Profile and -Category are ignored for -Full backups.' }
            $src = Join-Path $staging "$srcChannel\UserData"
            if (-not $fresh) { Write-Warning 'Full backup restored with Merge: files are copied over the existing User Data (nothing is moved aside).' }
            if ($PSCmdlet.ShouldProcess($userData, 'Restore full User Data backup')) {
                $copySw = [System.Diagnostics.Stopwatch]::StartNew()
                $restoredBytes = Get-EdgePathSize -Path $src
                Write-EdgeNote ('Copying the full User Data backup ({0}) to {1}...' -f (Format-EdgeSize $restoredBytes), $userData) -Level Step
                Invoke-EdgeRobocopy -Source $src -Destination $userData
                Write-EdgeNote ('User Data copied in {0}.' -f (Format-EdgeDuration $copySw.Elapsed))
                & $addResult $ch '*' '*' 'Full' 'Restored' $null
            }
        }
        else {
            if ($fresh -and $PSCmdlet.ShouldProcess($userData, 'Create User Data with the backup profiles')) {
                Write-EdgeNote "Creating a fresh User Data folder with $($backupProfiles.Count) profile(s)..." -Level Info
                Initialize-EdgeRestoreLocalState -UserDataPath $userData -Profile $backupProfiles -SameMachine $sameMachine
            }
            $localProfiles = (Test-Path -LiteralPath $userData) ? @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $userData) : @()

            # Size of every staged category, so the bar can move by bytes.
            $catSize = @{}
            [long]$totalBytes = 0
            foreach ($bp in $backupProfiles) {
                $bpCats = @($bp['Categories'])
                foreach ($cat in $wanted) {
                    if ($cat.Name -notin $bpCats) { continue }
                    $s = Get-EdgePathSize -Path (Join-Path $staging "$srcChannel\$([string]$bp['Key'])\$($cat.Name)")
                    $catSize["$([string]$bp['Key'])|$($cat.Name)"] = $s
                    $totalBytes += $s
                }
            }
            $progress = New-EdgeProgress -Activity "Restoring Edge $ch profiles" -Total $totalBytes -Id 1
            $profCount = $backupProfiles.Count
            $pIndex = 0
            $table = New-EdgeTable -Columns @(
                @{ Name = '#'; Width = [Math]::Max(3, "$profCount".Length); Align = 'Right' }
                @{ Name = 'Profile'; Width = 28 }
                @{ Name = 'Folder'; Width = 11 }
                @{ Name = 'Restored'; Width = 8; Align = 'Right' }
                @{ Name = 'Skipped'; Width = 7; Align = 'Right' }
                @{ Name = 'Size'; Width = 10; Align = 'Right' }
                @{ Name = 'Time'; Width = 8; Align = 'Right' }
                @{ Name = 'Note'; Width = 0 }
            )
            Write-EdgeTableHeader -Table $table
            $totRestored = 0; $totSkipped = 0

            foreach ($bp in $backupProfiles) {
                $pIndex++
                $key = [string]$bp['Key']; $name = [string]$bp['Name']
                $pSw = [System.Diagnostics.Stopwatch]::StartNew()
                [long]$pTotal = 0
                foreach ($k in @($catSize.Keys | Where-Object { $_ -like "$key|*" })) { $pTotal += $catSize[$k] }
                $pStart = $progress.Done
                $pStatus = "Profile $pIndex/$profCount '$name'"
                Update-EdgeProgress -Progress $progress -Status $pStatus -CurrentOperation 'Preparing' -Force

                $target = $localProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
                $createdNote = ''
                if (-not $target -and $edgeRunning) {
                    Write-Warning "Profile '$name' does not exist yet; creating a profile needs Edge $ch closed. Skipped (close Edge or use -CloseEdge)."
                    & $addResult $ch $name $null '*' 'Skipped' 'Edge running: profile creation needs Edge closed'
                    Write-EdgeTableRow -Table $table -Values @($pIndex, $name, '(new)', '', 'all', '', '', 'skipped: creating a profile needs Edge closed') -Level Warning
                    $profSkipped++
                    Update-EdgeProgress -Progress $progress -Done ($pStart + $pTotal)
                    continue
                }
                if ($target -and $edgeRunning -and (Test-EdgeProfileInUse -Path $target.Path)) {
                    Write-Warning "Profile '$name' ($($target.Directory)) is open in Edge $ch. Skipped (close its window(s), or use -CloseEdge)."
                    & $addResult $ch $name $target.Directory '*' 'Skipped' 'Profile is loaded in Edge'
                    Write-EdgeTableRow -Table $table -Values @($pIndex, $name, $target.Directory, '', 'all', '', '', 'skipped: profile is open in Edge') -Level Warning
                    $profSkipped++
                    Update-EdgeProgress -Progress $progress -Done ($pStart + $pTotal)
                    continue
                }
                if (-not $target) {
                    if ($PSCmdlet.ShouldProcess("Edge $ch", "Create profile '$name'")) {
                        $target = New-EdgeLocalProfile -Name $name -InfoCache $bp['InfoCache'] -Channel $ch -UserDataRoot $userData -WhatIf:$false -Confirm:$false
                        $createdNote = 'new profile'
                    }
                    else {
                        & $addResult $ch $name $null '*' 'WouldCreateProfile' $null
                        Write-EdgeTableRow -Table $table -Values @($pIndex, $name, '(new)', '', '', '', '', 'would be created (WhatIf)') -Level Step
                        Update-EdgeProgress -Progress $progress -Done ($pStart + $pTotal)
                        continue
                    }
                }

                $replacedRoot = Join-Path $userData "EdgeProfileSync-replaced\$timestamp\$($target.Directory)"
                $bpCats = @($bp['Categories'])
                $nRestored = 0; $nWhatIf = 0; $nFailed = 0
                [long]$pBytes = 0
                $skipReasons = [System.Collections.Generic.List[string]]::new()
                foreach ($cat in $wanted) {
                    if ($cat.Name -notin $bpCats) { continue }
                    $catSrc = Join-Path $staging "$srcChannel\$key\$($cat.Name)"
                    if (-not (Test-Path -LiteralPath $catSrc -PathType Container)) { continue }
                    $cBytes = [long]$catSize["$key|$($cat.Name)"]
                    Update-EdgeProgress -Progress $progress -Status "$pStatus - $($cat.Name)" -CurrentOperation ('{0} -> {1} ({2})' -f $cat.Name, $target.Directory, (Format-EdgeSize $cBytes))
                    if ($cat.SameMachineOnly -and -not $sameMachine) {
                        & $addResult $ch $name $target.Directory $cat.Name 'Skipped' 'Backup is from another machine'
                        $skipReasons.Add("$($cat.Name): same-machine only")
                        Update-EdgeProgress -Progress $progress -Add $cBytes
                        continue
                    }
                    if ($cat.Generated) {
                        Update-EdgeProgress -Progress $progress -Add $cBytes
                        continue   # ExtensionList: reported after all categories are restored
                    }
                    if (-not $PSCmdlet.ShouldProcess("$($target.Path) [$($cat.Name)]", 'Restore')) {
                        & $addResult $ch $name $target.Directory $cat.Name 'WhatIf' $null
                        $nWhatIf++; $pBytes += $cBytes
                        Update-EdgeProgress -Progress $progress -Add $cBytes
                        continue
                    }
                    try {
                        Restore-EdgeCategoryFromStage -StagePath $catSrc -ProfilePath $target.Path -Category $cat -ReplacedRoot (Join-Path $replacedRoot $cat.Name)
                        & $addResult $ch $name $target.Directory $cat.Name 'Restored' $null
                        $nRestored++
                        $pBytes += $cBytes
                    }
                    catch {
                        Write-EdgeSyncLog -Message "Restore Edge $ch '$key' $($cat.Name) failed: $($_.Exception.Message)" -Level Warning
                        & $addResult $ch $name $target.Directory $cat.Name 'Error' $_.Exception.Message
                        $nFailed++
                    }
                    Update-EdgeProgress -Progress $progress -Add $cBytes
                }

                # ---- extensions: compare the backup inventory with what is installed now
                $extFile = Join-Path $staging "$srcChannel\$key\ExtensionList\extensions.json"
                $extNote = ''
                if ((@($wanted | ForEach-Object { $_.Name }) -contains 'ExtensionList') -and (Test-Path -LiteralPath $extFile -PathType Leaf)) {
                    Update-EdgeProgress -Progress $progress -Status "$pStatus - ExtensionList" -CurrentOperation 'Comparing extensions with the backup' -Force
                    $missing = @(Update-EdgePendingFromBackup -InventoryFile $extFile -Channel $ch -ProfileKey $target.Key -ProfilePath $target.Path -ProfileName $name -Cmdlet $PSCmdlet)
                    & $addResult $ch $name $target.Directory 'ExtensionList' 'Reported' "$($missing.Count) extension(s) to install"
                    $pendingTotal += $missing.Count
                    if ($missing.Count) { $extNote = "$($missing.Count) extension(s) to install" }
                }
                Update-EdgeProgress -Progress $progress -Done ($pStart + $pTotal)
                $restoredBytes += $pBytes
                $pSw.Stop()

                $notes = [System.Collections.Generic.List[string]]::new()
                if ($createdNote) { $notes.Add($createdNote) }
                if ($WhatIfPreference -and $nWhatIf) { $notes.Add('WhatIf') }
                if ($nFailed) { $notes.Add("$nFailed failed (see log)") }
                if ($skipReasons.Count) { $notes.Add("skipped: $($skipReasons -join ', ')") }
                if ($extNote) { $notes.Add($extNote) }
                $nDone = ($WhatIfPreference -and $nWhatIf) ? $nWhatIf : $nRestored
                $totRestored += $nDone; $totSkipped += $skipReasons.Count
                $rowLevel = $nFailed ? 'Warning' : (($nRestored -or $nWhatIf) ? 'Info' : 'Warning')
                Write-EdgeTableRow -Table $table -Values @($pIndex, $name, $target.Directory, $nDone, ($skipReasons.Count ? $skipReasons.Count : ''),
                    (Format-EdgeSize $pBytes), (Format-EdgeDuration $pSw.Elapsed), ($notes -join '; ')) -Level $rowLevel
                if ($nFailed) { $profFailed++ }
                elseif ($nRestored -or $nWhatIf) { $profRestored++ }
                else { $profSkipped++ }
            }
            Complete-EdgeProgress -Progress $progress
            $progress = $null
            Write-EdgeTableRule -Table $table
            Write-EdgeTableRow -Table $table -Values @('', 'Total', '', $totRestored, ($totSkipped ? $totSkipped : ''), (Format-EdgeSize $restoredBytes), (Format-EdgeDuration $sw.Elapsed), '')
        }

        # ---- registry
        if ($ImportRegistry) {
            $regFile = $manifest['Registry'] ? (Join-Path $staging ([string]$manifest['Registry'])) : $null
            if (-not $sameMachine) { Write-Warning 'The registry export is machine-bound; not imported because the backup is from another machine.' }
            elseif ($UserDataRoot) { Write-Verbose 'Test User Data root in use; registry import skipped.' }
            elseif (-not $regFile -or -not (Test-Path -LiteralPath $regFile)) { Write-Warning 'The backup contains no registry export.' }
            elseif ($PSCmdlet.ShouldProcess($info.RegistryKey, 'Import registry export from backup')) {
                Write-EdgeNote 'Importing the registry export from the backup...' -Level Info
                Import-EdgeRegistryFile -Path $regFile
            }
        }

        if ($ExistingDataAction -eq 'Remove' -and $oldUserData -and $PSCmdlet.ShouldProcess($oldUserData, 'Delete previous User Data')) {
            Write-EdgeNote "Deleting previous User Data '$oldUserData'..." -Level Info
            Remove-Item -LiteralPath $oldUserData -Recurse -Force
        }

        $sw.Stop()
        $restored = @($results | Where-Object Action -eq 'Restored')
        $skipped = @($results | Where-Object Action -eq 'Skipped')
        $failed = @($results | Where-Object Action -eq 'Error')
        $msg = 'Edge {0} restore: {1} profile(s), {2} item(s) restored, {3} skipped, {4} failed, {5}, in {6}{7}.' -f $ch,
            @($backupProfiles).Count, $restored.Count, $skipped.Count, $failed.Count, (Format-EdgeSize $restoredBytes), (Format-EdgeDuration $sw.Elapsed),
            ($oldUserData ? "; previous User Data: $oldUserData" : '')
        Write-EdgeSyncLog -Message $msg -Level Info

        $replacedDir = Join-Path $userData "EdgeProfileSync-replaced\$timestamp"
        $boxLevel = ($failed -or $profFailed) ? 'Warning' : 'Success'
        Write-EdgeBox -Title ('Restore {0} in {1}' -f ($WhatIfPreference ? 'preview (WhatIf) finished' : 'finished'), (Format-EdgeDuration $sw.Elapsed)) -Level $boxLevel -Rows ([ordered]@{
                'Profiles'   = $manifest['Full'] ? $null : ('{0} {1}, {2} skipped, {3} failed (of {4})' -f $profRestored, ($WhatIfPreference ? 'would be restored' : 'restored'), $profSkipped, $profFailed, $backupProfiles.Count)
                'Categories' = '{0} restored, {1} skipped, {2} failed ({3})' -f $restored.Count, $skipped.Count, $failed.Count, (Format-EdgeSize $restoredBytes)
                'Replaced'   = (Test-Path -LiteralPath $replacedDir -PathType Container) ? "replaced files are kept in '$replacedDir'" : $null
                'Previous'   = ($oldUserData -and (Test-Path -LiteralPath $oldUserData)) ? "previous User Data: '$oldUserData' (delete it when everything works)" : $null
                'Extensions' = $pendingTotal ? "$pendingTotal extension(s) to install: run Install-EdgeProfileExtension" : $null
                'Failures'   = $failed ? (($failed | ForEach-Object { "$($_.Profile)/$($_.Category): $($_.Reason)" }) -join '; ') : $null
            })
        if ($PassThru) { $results }
    }
    finally {
        if ($progress) { Complete-EdgeProgress -Progress $progress }
        if (-not $isFolder) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore -WhatIf:$false -Confirm:$false }
    }
}
