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
    Write-EdgeStatus ''
    Write-EdgeStatus ("Restore of Edge backup '{0}' ({1}{2})" -f (Split-Path $zipPath -Leaf), (Format-EdgeSize $zipSize), ($isFolder ? ', folder' : '')) -Level Header
    Write-EdgeStatus "  Backup      : $zipPath" -Level Header

    $staging = $isFolder ? $zipPath : (Join-Path ([System.IO.Path]::GetTempPath()) "EdgeProfileSync-restore-$([guid]::NewGuid().ToString('N').Substring(0, 12))")
    $progress = $null
    try {
        if ($isFolder) {
            $isV2 = Test-Path -LiteralPath (Join-Path $staging 'backup-manifest.json') -PathType Leaf
            if (-not $isV2) { throw "'$zipPath' is a folder but contains no backup-manifest.json (not made by Backup-EdgeProfiles -Format Folder)." }
            Write-EdgeStatus 'Folder backup: restoring directly from the folder (no extraction needed).' -Level Step
        }
        else {
            Write-Verbose "Extracting '$zipPath' to '$staging'"
            Write-EdgeStatus "Extracting the backup to a temporary folder..." -Level Step
            $extract = Expand-EdgeZipToDirectory -ZipPath $zipPath -Destination $staging -Activity "Extracting $(Split-Path $zipPath -Leaf)"
            $isV2 = $extract.IsV2
            Write-EdgeStatus ('Extracted {0} file(s), {1} in {2}.' -f $extract.Files, (Format-EdgeSize $extract.Bytes), (Format-EdgeDuration $extract.Duration))
        }

        # ------------------------------------------------------------------ 1.x zip
        if (-not $isV2) {
            $ch = $Channel ? $Channel : 'Stable'
            $info = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
            $userData = $info.UserDataPath
            Write-EdgeStatus "Legacy EDGEProfiles 1.x backup detected; restoring the whole User Data folder of Edge $ch (action: $ExistingDataAction)."
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
            if ($oldUserData) { Write-EdgeStatus "Previous User Data renamed to '$oldUserData'." -Level Step }

            if ($PSCmdlet.ShouldProcess($userData, 'Restore User Data from 1.x backup')) {
                $copySw = [System.Diagnostics.Stopwatch]::StartNew()
                Write-EdgeStatus ('Copying User Data ({0}) to {1}...' -f (Format-EdgeSize (Get-EdgePathSize -Path $src)), $userData) -Level Step
                Invoke-EdgeRobocopy -Source $src -Destination $userData
                Write-EdgeStatus ('User Data copied in {0}.' -f (Format-EdgeDuration $copySw.Elapsed))
                & $addResult $ch '*' '*' 'Legacy' 'Restored' $zipPath
            }
            if ($REGSource) {
                if ($UserDataRoot) { Write-Verbose 'Test User Data root in use; registry import skipped.' }
                elseif (-not (Test-Path -LiteralPath $REGSource -PathType Leaf)) { Write-Warning "Registry file '$REGSource' not found; not imported." }
                elseif ($PSCmdlet.ShouldProcess($REGSource, 'Import registry file')) {
                    Write-EdgeStatus "Importing registry file '$REGSource'..." -Level Step
                    Import-EdgeRegistryFile -Path $REGSource
                }
            }
            if ($ExistingDataAction -eq 'Remove' -and $oldUserData -and $PSCmdlet.ShouldProcess($oldUserData, 'Delete previous User Data')) {
                Write-EdgeStatus "Deleting previous User Data '$oldUserData'..." -Level Step
                Remove-Item -LiteralPath $oldUserData -Recurse -Force
            }
            $sw.Stop()
            Write-EdgeStatus ('Edge {0} restore (1.x backup) completed in {1}.{2}' -f $ch, (Format-EdgeDuration $sw.Elapsed),
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
        Write-EdgeStatus ('  Created     : {0} on {1}{2}' -f ($created ? $created : 'unknown'), ($origin ? ($origin -join ' / ') : 'unknown machine'),
            ($sameMachine ? ' (this machine)' : ' (another machine)')) -Level Header
        Write-EdgeStatus ('  Channel     : Edge {0}{1} -> {2}' -f $srcChannel, ($manifest['Full'] ? ' (full User Data backup)' : ''), $userData) -Level Header
        if (-not $manifest['Full']) {
            Write-EdgeStatus ('  Profiles    : {0} of {1} in the backup{2}' -f $backupProfiles.Count, @($manifest['Profiles']).Count,
                ($backupProfiles ? ": $(($backupProfiles | ForEach-Object { [string]$_['Name'] }) -join ', ')" : '')) -Level Header
            Write-EdgeStatus ('  Categories  : {0}' -f ($wanted ? (($wanted | ForEach-Object { $_.Name }) -join ', ') : '(none)')) -Level Header
        }
        Write-EdgeStatus ('  Action      : {0}{1}{2}' -f $ExistingDataAction, ($CloseEdge ? ', close Edge' : ''), ($WhatIfPreference ? ' (WhatIf: nothing is changed)' : '')) -Level Header
        if (-not $sameMachine) {
            Write-EdgeStatus "Backup was made on '$($manifest['MachineId'])' (this machine: '$machineId'): machine-bound data (SecurePreferences, Extensions, registry) is not restored." -Level Warning
        }

        if (-not $backupProfiles -and -not $manifest['Full']) {
            Write-Warning "No profiles in the backup match$($ProfileName ? " '$($ProfileName -join "', '")'" : '')."
            return
        }

        # Replacing User Data or a full backup needs Edge closed; a Merge only needs the target
        # profiles to be not loaded (checked per profile below).
        $requireClosed = $ExistingDataAction -ne 'Merge' -or [bool]$manifest['Full']
        $edgeRunning = Assert-EdgeRestoreAllowed -Channel $ch -CloseEdge:$CloseEdge -RequireClosed:$requireClosed -Cmdlet $PSCmdlet
        if ($edgeRunning) { Write-EdgeStatus "Edge $ch is running: profiles that are open in Edge, and profiles that have to be created, are skipped." -Level Warning }

        $fresh = $ExistingDataAction -ne 'Merge' -or -not (Test-Path -LiteralPath $userData -PathType Container)
        $oldUserData = Move-EdgeUserDataAside -UserDataPath $userData -Action $ExistingDataAction -Timestamp $timestamp -Force:$Force -Cmdlet $PSCmdlet
        if ($null -eq $oldUserData -and $ExistingDataAction -ne 'Merge' -and (Test-Path -LiteralPath $userData) -and -not $WhatIfPreference) { return }
        if ($oldUserData) { Write-EdgeStatus "Previous User Data renamed to '$oldUserData'." -Level Step }

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
                Write-EdgeStatus ('Copying the full User Data backup ({0}) to {1}...' -f (Format-EdgeSize $restoredBytes), $userData) -Level Step
                Invoke-EdgeRobocopy -Source $src -Destination $userData
                Write-EdgeStatus ('User Data copied in {0}.' -f (Format-EdgeDuration $copySw.Elapsed))
                & $addResult $ch '*' '*' 'Full' 'Restored' $null
            }
        }
        else {
            if ($fresh -and $PSCmdlet.ShouldProcess($userData, 'Create User Data with the backup profiles')) {
                Write-EdgeStatus "Creating a fresh User Data folder with $($backupProfiles.Count) profile(s)..." -Level Step
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
            $width = "$profCount".Length
            $pIndex = 0

            foreach ($bp in $backupProfiles) {
                $pIndex++
                $key = [string]$bp['Key']; $name = [string]$bp['Name']
                $tag = "[{0,$width}/{1}]" -f $pIndex, $profCount
                $pSw = [System.Diagnostics.Stopwatch]::StartNew()
                [long]$pTotal = 0
                foreach ($k in @($catSize.Keys | Where-Object { $_ -like "$key|*" })) { $pTotal += $catSize[$k] }
                $pStart = $progress.Done
                $pStatus = "Profile $pIndex/$profCount '$name'"
                Update-EdgeProgress -Progress $progress -Status $pStatus -CurrentOperation 'Preparing' -Force

                $target = $localProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
                if (-not $target -and $edgeRunning) {
                    Write-Warning "Profile '$name' does not exist yet; creating a profile needs Edge $ch closed. Skipped (close Edge or use -CloseEdge)."
                    & $addResult $ch $name $null '*' 'Skipped' 'Edge running: profile creation needs Edge closed'
                    Write-EdgeStatus "$tag ${name}: skipped - needs Edge closed (profile has to be created)" -Level Warning
                    $profSkipped++
                    Update-EdgeProgress -Progress $progress -Done ($pStart + $pTotal)
                    continue
                }
                if ($target -and $edgeRunning -and (Test-EdgeProfileInUse -Path $target.Path)) {
                    Write-Warning "Profile '$name' ($($target.Directory)) is open in Edge $ch. Skipped (close its window(s), or use -CloseEdge)."
                    & $addResult $ch $name $target.Directory '*' 'Skipped' 'Profile is loaded in Edge'
                    Write-EdgeStatus "$tag $name -> $($target.Directory): skipped - loaded in Edge" -Level Warning
                    $profSkipped++
                    Update-EdgeProgress -Progress $progress -Done ($pStart + $pTotal)
                    continue
                }
                if (-not $target) {
                    if ($PSCmdlet.ShouldProcess("Edge $ch", "Create profile '$name'")) {
                        $target = New-EdgeLocalProfile -Name $name -InfoCache $bp['InfoCache'] -Channel $ch -UserDataRoot $userData -WhatIf:$false -Confirm:$false
                        Write-EdgeStatus "$tag Created profile '$name' ($($target.Directory))." -Level Step
                    }
                    else {
                        & $addResult $ch $name $null '*' 'WouldCreateProfile' $null
                        Write-EdgeStatus "$tag ${name}: would be created as a new profile (WhatIf)" -Level Step
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
                    if ($missing.Count) { $extNote = "; $($missing.Count) extension(s) to install" }
                }
                Update-EdgeProgress -Progress $progress -Done ($pStart + $pTotal)
                $restoredBytes += $pBytes
                $pSw.Stop()

                $parts = [System.Collections.Generic.List[string]]::new()
                if ($WhatIfPreference -and $nWhatIf) { $parts.Add("$nWhatIf categories would be restored") }
                else { $parts.Add("$nRestored categories restored") }
                if ($skipReasons.Count) { $parts.Add("$($skipReasons.Count) skipped ($($skipReasons -join ', '))") }
                if ($nFailed) { $parts.Add("$nFailed failed") }
                $line = '{0} {1} -> {2}: {3} ({4}, {5}){6}' -f $tag, $name, $target.Directory, ($parts -join ', '),
                    (Format-EdgeSize $pBytes), (Format-EdgeDuration $pSw.Elapsed), $extNote
                if ($nFailed) { $profFailed++; Write-EdgeStatus $line -Level Warning }
                elseif ($nRestored -or $nWhatIf) { $profRestored++; Write-EdgeStatus $line -Level Info }
                else { $profSkipped++; Write-EdgeStatus $line -Level Warning }
            }
            Complete-EdgeProgress -Progress $progress
            $progress = $null
        }

        # ---- registry
        if ($ImportRegistry) {
            $regFile = $manifest['Registry'] ? (Join-Path $staging ([string]$manifest['Registry'])) : $null
            if (-not $sameMachine) { Write-Warning 'The registry export is machine-bound; not imported because the backup is from another machine.' }
            elseif ($UserDataRoot) { Write-Verbose 'Test User Data root in use; registry import skipped.' }
            elseif (-not $regFile -or -not (Test-Path -LiteralPath $regFile)) { Write-Warning 'The backup contains no registry export.' }
            elseif ($PSCmdlet.ShouldProcess($info.RegistryKey, 'Import registry export from backup')) {
                Write-EdgeStatus 'Importing the registry export from the backup...' -Level Step
                Import-EdgeRegistryFile -Path $regFile
            }
        }

        if ($ExistingDataAction -eq 'Remove' -and $oldUserData -and $PSCmdlet.ShouldProcess($oldUserData, 'Delete previous User Data')) {
            Write-EdgeStatus "Deleting previous User Data '$oldUserData'..." -Level Step
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

        Write-EdgeStatus ('Restore of Edge {0} finished in {1}' -f $ch, (Format-EdgeDuration $sw.Elapsed)) -Level ($failed ? 'Warning' : 'Success')
        if (-not $manifest['Full']) {
            Write-EdgeStatus ('  Profiles    : {0} {1}, {2} skipped, {3} failed (of {4})' -f $profRestored, ($WhatIfPreference ? 'would be restored' : 'restored'), $profSkipped, $profFailed, $backupProfiles.Count) -Level ($profFailed ? 'Warning' : 'Success')
        }
        Write-EdgeStatus ('  Categories  : {0} restored, {1} skipped, {2} failed ({3})' -f $restored.Count, $skipped.Count, $failed.Count, (Format-EdgeSize $restoredBytes)) -Level ($failed ? 'Warning' : 'Success')
        $replacedDir = Join-Path $userData "EdgeProfileSync-replaced\$timestamp"
        if (Test-Path -LiteralPath $replacedDir -PathType Container) { Write-EdgeStatus "  Replaced    : the files that were replaced are in '$replacedDir'" }
        if ($oldUserData -and (Test-Path -LiteralPath $oldUserData)) { Write-EdgeStatus "  Previous    : the previous User Data is in '$oldUserData'" }
        if ($pendingTotal) { Write-EdgeStatus "  Extensions  : $pendingTotal extension(s) still to install; run Install-EdgeProfileExtension." -Level Warning }
        if ($failed) { Write-EdgeStatus "  Failures    : $(($failed | ForEach-Object { "$($_.Profile)/$($_.Category): $($_.Reason)" }) -join '; ')" -Level Warning }
        if ($PassThru) { $results }
    }
    finally {
        if ($progress) { Complete-EdgeProgress -Progress $progress }
        if (-not $isFolder) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore -WhatIf:$false -Confirm:$false }
    }
}
