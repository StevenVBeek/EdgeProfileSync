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
        The backup zip (alias: ZIPSource, as in EDGEProfiles 1.x).

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

    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $isV2 = $null -ne $zip.GetEntry('backup-manifest.json')
    }
    finally { $zip.Dispose() }

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "EdgeProfileSync-restore-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    try {
        Write-Verbose "Extracting '$zipPath' to '$staging'"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $staging)

        # ------------------------------------------------------------------ 1.x zip
        if (-not $isV2) {
            $ch = $Channel ? $Channel : 'Stable'
            $info = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
            $userData = $info.UserDataPath
            Write-Host "Legacy EDGEProfiles 1.x backup detected; restoring the whole User Data folder of Edge $ch."
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

            if ($PSCmdlet.ShouldProcess($userData, 'Restore User Data from 1.x backup')) {
                Invoke-EdgeRobocopy -Source $src -Destination $userData
                & $addResult $ch '*' '*' 'Legacy' 'Restored' $zipPath
            }
            if ($REGSource) {
                if ($UserDataRoot) { Write-Verbose 'Test User Data root in use; registry import skipped.' }
                elseif (-not (Test-Path -LiteralPath $REGSource -PathType Leaf)) { Write-Warning "Registry file '$REGSource' not found; not imported." }
                elseif ($PSCmdlet.ShouldProcess($REGSource, 'Import registry file')) { Import-EdgeRegistryFile -Path $REGSource }
            }
            if ($ExistingDataAction -eq 'Remove' -and $oldUserData -and $PSCmdlet.ShouldProcess($oldUserData, 'Delete previous User Data')) {
                Remove-Item -LiteralPath $oldUserData -Recurse -Force
            }
            $sw.Stop()
            Write-Host ('Edge {0} restore (1.x backup) completed in {1:N1} s.' -f $ch, $sw.Elapsed.TotalSeconds)
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
        if (-not $sameMachine) {
            Write-Host "Backup was made on '$($manifest['MachineId'])' (this machine: '$machineId'): machine-bound data (SecurePreferences, Extensions, registry) is not restored."
        }

        # categories to restore
        $inBackup = @($manifest['Categories'])
        $wanted = if (-not $Category -or $Category -contains 'All') { @(Get-EdgeDataCategory | Where-Object Name -in $inBackup) }
        else { @(Resolve-EdgeBackupCategory -Category $Category | Where-Object Name -in $inBackup) }

        $backupProfiles = @(Select-EdgeProfileByFilter -InputObject @($manifest['Profiles']) -Filter $ProfileName)
        if (-not $backupProfiles -and -not $manifest['Full']) {
            Write-Warning "No profiles in the backup match$($ProfileName ? " '$($ProfileName -join "', '")'" : '')."
            return
        }

        # Replacing User Data or a full backup needs Edge closed; a Merge only needs the target
        # profiles to be not loaded (checked per profile below).
        $requireClosed = $ExistingDataAction -ne 'Merge' -or [bool]$manifest['Full']
        $edgeRunning = Assert-EdgeRestoreAllowed -Channel $ch -CloseEdge:$CloseEdge -RequireClosed:$requireClosed -Cmdlet $PSCmdlet

        $fresh = $ExistingDataAction -ne 'Merge' -or -not (Test-Path -LiteralPath $userData -PathType Container)
        $oldUserData = Move-EdgeUserDataAside -UserDataPath $userData -Action $ExistingDataAction -Timestamp $timestamp -Force:$Force -Cmdlet $PSCmdlet
        if ($null -eq $oldUserData -and $ExistingDataAction -ne 'Merge' -and (Test-Path -LiteralPath $userData) -and -not $WhatIfPreference) { return }

        if ($manifest['Full']) {
            # ---- full User Data backup
            if ($ProfileName -or $Category) { Write-Warning '-Profile and -Category are ignored for -Full backups.' }
            $src = Join-Path $staging "$srcChannel\UserData"
            if (-not $fresh) { Write-Warning 'Full backup restored with Merge: files are copied over the existing User Data (nothing is moved aside).' }
            if ($PSCmdlet.ShouldProcess($userData, 'Restore full User Data backup')) {
                Invoke-EdgeRobocopy -Source $src -Destination $userData
                & $addResult $ch '*' '*' 'Full' 'Restored' $null
            }
        }
        else {
            if ($fresh -and $PSCmdlet.ShouldProcess($userData, 'Create User Data with the backup profiles')) {
                Initialize-EdgeRestoreLocalState -UserDataPath $userData -Profile $backupProfiles -SameMachine $sameMachine
            }
            $localProfiles = (Test-Path -LiteralPath $userData) ? @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $userData) : @()

            foreach ($bp in $backupProfiles) {
                $key = [string]$bp['Key']; $name = [string]$bp['Name']
                $target = $localProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
                if (-not $target -and $edgeRunning) {
                    Write-Warning "Profile '$name' does not exist yet; creating a profile needs Edge $ch closed. Skipped (close Edge or use -CloseEdge)."
                    & $addResult $ch $name $null '*' 'Skipped' 'Edge running: profile creation needs Edge closed'
                    continue
                }
                if ($target -and $edgeRunning -and (Test-EdgeProfileInUse -Path $target.Path)) {
                    Write-Warning "Profile '$name' ($($target.Directory)) is open in Edge $ch. Skipped (close its window(s), or use -CloseEdge)."
                    & $addResult $ch $name $target.Directory '*' 'Skipped' 'Profile is loaded in Edge'
                    continue
                }
                if (-not $target) {
                    if ($PSCmdlet.ShouldProcess("Edge $ch", "Create profile '$name'")) {
                        $target = New-EdgeLocalProfile -Name $name -InfoCache $bp['InfoCache'] -Channel $ch -UserDataRoot $userData -WhatIf:$false -Confirm:$false
                        Write-Host "Created profile '$name' ($($target.Directory))."
                    }
                    else {
                        & $addResult $ch $name $null '*' 'WouldCreateProfile' $null
                        continue
                    }
                }

                $replacedRoot = Join-Path $userData "EdgeProfileSync-replaced\$timestamp\$($target.Directory)"
                $bpCats = @($bp['Categories'])
                foreach ($cat in $wanted) {
                    if ($cat.Name -notin $bpCats) { continue }
                    $catSrc = Join-Path $staging "$srcChannel\$key\$($cat.Name)"
                    if (-not (Test-Path -LiteralPath $catSrc -PathType Container)) { continue }
                    if ($cat.SameMachineOnly -and -not $sameMachine) {
                        & $addResult $ch $name $target.Directory $cat.Name 'Skipped' 'Backup is from another machine'
                        continue
                    }
                    if ($cat.Generated) {
                        continue   # ExtensionList: reported after all categories are restored
                    }
                    if (-not $PSCmdlet.ShouldProcess("$($target.Path) [$($cat.Name)]", 'Restore')) {
                        & $addResult $ch $name $target.Directory $cat.Name 'WhatIf' $null
                        continue
                    }
                    try {
                        Restore-EdgeCategoryFromStage -StagePath $catSrc -ProfilePath $target.Path -Category $cat -ReplacedRoot (Join-Path $replacedRoot $cat.Name)
                        & $addResult $ch $name $target.Directory $cat.Name 'Restored' $null
                    }
                    catch {
                        Write-EdgeSyncLog -Message "Restore Edge $ch '$key' $($cat.Name) failed: $($_.Exception.Message)" -Level Warning
                        & $addResult $ch $name $target.Directory $cat.Name 'Error' $_.Exception.Message
                    }
                }

                # ---- extensions: compare the backup inventory with what is installed now
                $extFile = Join-Path $staging "$srcChannel\$key\ExtensionList\extensions.json"
                if ((@($wanted | ForEach-Object { $_.Name }) -contains 'ExtensionList') -and (Test-Path -LiteralPath $extFile -PathType Leaf)) {
                    $missing = @(Update-EdgePendingFromBackup -InventoryFile $extFile -Channel $ch -ProfileKey $target.Key -ProfilePath $target.Path -ProfileName $name -Cmdlet $PSCmdlet)
                    & $addResult $ch $name $target.Directory 'ExtensionList' 'Reported' "$($missing.Count) extension(s) to install"
                }
            }
        }

        # ---- registry
        if ($ImportRegistry) {
            $regFile = $manifest['Registry'] ? (Join-Path $staging ([string]$manifest['Registry'])) : $null
            if (-not $sameMachine) { Write-Warning 'The registry export is machine-bound; not imported because the backup is from another machine.' }
            elseif ($UserDataRoot) { Write-Verbose 'Test User Data root in use; registry import skipped.' }
            elseif (-not $regFile -or -not (Test-Path -LiteralPath $regFile)) { Write-Warning 'The backup contains no registry export.' }
            elseif ($PSCmdlet.ShouldProcess($info.RegistryKey, 'Import registry export from backup')) { Import-EdgeRegistryFile -Path $regFile }
        }

        if ($ExistingDataAction -eq 'Remove' -and $oldUserData -and $PSCmdlet.ShouldProcess($oldUserData, 'Delete previous User Data')) {
            Remove-Item -LiteralPath $oldUserData -Recurse -Force
        }

        $sw.Stop()
        $restored = @($results | Where-Object Action -eq 'Restored')
        $skipped = @($results | Where-Object Action -eq 'Skipped')
        $msg = 'Edge {0} restore: {1} profile(s), {2} item(s) restored, {3} skipped, in {4:N1} s{5}.' -f $ch,
            @($backupProfiles).Count, $restored.Count, $skipped.Count, $sw.Elapsed.TotalSeconds,
            ($oldUserData ? "; previous User Data: $oldUserData" : '')
        Write-Host $msg
        Write-EdgeSyncLog -Message $msg -Level Info
        if ($PassThru) { $results }
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Ignore -WhatIf:$false -Confirm:$false
    }
}
