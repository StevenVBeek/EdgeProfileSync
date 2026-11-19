function Remove-EdgeProfile {
    <#
    .SYNOPSIS
        Removes Edge profiles (bulk cleanup), after making a backup of them.

    .DESCRIPTION
        Removes the selected profiles from Edge: unregisters them in 'Local State' and sends the
        profile folder to the Recycle Bin (-Permanent deletes it). Before that, a backup zip of all
        categories of the profiles is made with Backup-EdgeProfiles (skip with -SkipBackup).

        Profiles can be selected with -Name, -Key or -Directory (wildcards), or piped in from
        Get-EdgeProfile. Orphan folders (Get-EdgeProfile -All) can be removed too.

        Unless -LocalOnly, a tombstone is written to the sync store so that Sync-EdgeProfiles on other
        machines does not re-create the profile.

        Edge of the channel must be fully closed (removing a profile rewrites Local State, which Edge
        overwrites on exit); -CloseEdge stops it. The 'Default' profile cannot be removed.

        Asks for confirmation per profile (ConfirmImpact High) unless -Force or -Confirm:$false.

    .PARAMETER Name
        Display name(s) of the profiles to remove (wildcards allowed).

    .PARAMETER Key
        Key(s) of the profiles to remove (wildcards allowed).

    .PARAMETER Directory
        Profile folder name(s), e.g. 'Profile 7' (wildcards allowed). Bound from pipeline objects.

    .PARAMETER Channel
        Edge channel. Default: Stable. Bound from pipeline objects.

    .PARAMETER SkipBackup
        Do not make a backup zip first.

    .PARAMETER BackupDestination
        Folder for the backup zip. Default: the Backup-EdgeProfiles default folder.

    .PARAMETER Permanent
        Delete the profile folders instead of sending them to the Recycle Bin.

    .PARAMETER LocalOnly
        Do not write a tombstone to the sync store (other machines keep syncing the profile).

    .PARAMETER CloseEdge
        Stop Edge of the channel if it is running.

    .PARAMETER Force
        Do not ask for confirmation.

    .PARAMETER PassThru
        Return a summary object per profile.

    .EXAMPLE
        Get-EdgeProfile | Where-Object LastActiveUtc -lt (Get-Date).AddMonths(-6) | Remove-EdgeProfile

    .EXAMPLE
        Get-EdgeProfile | Out-ConsoleGridView | Remove-EdgeProfile -CloseEdge

        Interactive selection (needs the Microsoft.PowerShell.ConsoleGuiTools module).

    .EXAMPLE
        Remove-EdgeProfile -Name 'Test *' -Force -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string[]]$Name,

        [SupportsWildcards()]
        [string[]]$Key,

        [Parameter(ValueFromPipelineByPropertyName)]
        [SupportsWildcards()]
        [string[]]$Directory,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel = 'Stable',

        [switch]$SkipBackup,

        [string]$BackupDestination,

        [switch]$Permanent,

        [switch]$LocalOnly,

        [switch]$CloseEdge,

        [switch]$Force,

        [switch]$PassThru,

        [Parameter(DontShow)]
        [string]$UserDataRoot,

        [Parameter(DontShow)]
        [string]$SyncRoot
    )

    begin {
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
        $requests = [System.Collections.Generic.List[object]]::new()
    }

    process {
        $requests.Add([pscustomobject]@{
                Channel   = $Channel
                Name      = @($Name | Where-Object { $_ })
                Key       = @($Key | Where-Object { $_ })
                Directory = @($Directory | Where-Object { $_ })
            })
    }

    end {
        $requests = @($requests | Where-Object { $_.Name -or $_.Key -or $_.Directory })
        if (-not $requests) {
            Write-Error 'Specify -Name, -Key or -Directory, or pipe profiles from Get-EdgeProfile.'
            return
        }

        foreach ($chGroup in ($requests | Group-Object Channel)) {
            $ch = $chGroup.Name
            $info = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
            $local = @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $UserDataRoot)
            $all = $local + @(Get-EdgeOrphanProfile -UserDataPath $info.UserDataPath -Channel $ch -Registered $local)

            # Resolve the selection (each profile once).
            $selected = [ordered]@{}
            foreach ($r in $chGroup.Group) {
                $hits = @()
                if ($r.Name) { $hits += @(Select-EdgeProfileByFilter -InputObject $all -Filter $r.Name -Property Name) }
                if ($r.Key) { $hits += @(Select-EdgeProfileByFilter -InputObject $all -Filter $r.Key -Property Key) }
                if ($r.Directory) { $hits += @(Select-EdgeProfileByFilter -InputObject $all -Filter $r.Directory -Property Directory) }
                if (-not $hits) { Write-Warning "Edge ${ch}: no profile matches '$((@($r.Name) + @($r.Key) + @($r.Directory)) -join "', '")'." }
                foreach ($h in $hits) { $selected[$h.Directory] = $h }
            }
            $results = [System.Collections.Generic.List[object]]::new()
            $addResult = {
                param($p, $action, $reason, $backup, $tomb)
                $results.Add([pscustomobject]@{
                        Channel = $ch; Directory = $p.Directory; Name = $p.Name; Key = $p.Key
                        Action = $action; Reason = $reason; BackupPath = $backup; Tombstone = [bool]$tomb
                    })
            }

            # Confirm per profile.
            $confirmed = [System.Collections.Generic.List[object]]::new()
            foreach ($p in $selected.Values) {
                $isOrphan = [bool]($p.PSObject.Properties['IsOrphan'] -and $p.IsOrphan)
                if ($p.Directory -eq 'Default') {
                    Write-Warning "The 'Default' profile ('$($p.Name)') cannot be removed (Edge recreates it); skipped."
                    & $addResult $p 'Skipped' 'Default profile' $null $false
                    continue
                }
                $label = $isOrphan ? "orphan folder '$($p.Directory)'" : "profile '$($p.Name)' ($($p.Directory))"
                $how = $Permanent ? 'delete permanently' : 'move to the Recycle Bin'
                if ($PSCmdlet.ShouldProcess("Edge $ch $label", "Remove profile ($how)")) { $confirmed.Add($p) }
                else { & $addResult $p ($WhatIfPreference ? 'WhatIf' : 'Skipped') 'Not confirmed' $null $false }
            }

            if ($confirmed.Count) {
                # Edge must be fully closed.
                $state = Get-EdgeProcessState -Channel $ch
                if ($state.Running) {
                    if (-not $CloseEdge) {
                        throw "Edge $ch is running. Removing profiles rewrites Local State, so Edge must be fully closed (also check the system tray / Startup Boost), or use -CloseEdge."
                    }
                    if (-not (Stop-EdgeProcess -Channel $ch)) { throw "Edge $ch could not be stopped; nothing removed." }
                }

                # Backup first (registered profiles; orphan folders are not in Local State and cannot be backed up by key).
                $backupPath = $null
                $toBackup = @($confirmed | Where-Object { -not ($_.PSObject.Properties['IsOrphan'] -and $_.IsOrphan) })
                if (-not $SkipBackup -and $toBackup) {
                    $bArgs = @{
                        Channel     = $ch
                        ProfileName = @($toBackup | ForEach-Object { [WildcardPattern]::Escape($_.Directory) })
                        Category    = 'All'
                        PassThru    = $true
                    }
                    if ($BackupDestination) { $bArgs.Destination = $BackupDestination }
                    if ($UserDataRoot) { $bArgs.UserDataRoot = $UserDataRoot }
                    try { $backupPath = (Backup-EdgeProfiles @bArgs -ErrorAction Stop).Path }
                    catch { throw "Backup before removal failed, nothing removed: $($_.Exception.Message)" }
                    if (-not $backupPath) { throw 'Backup before removal produced no archive; nothing removed.' }
                }

                $syncRootPath = $LocalOnly ? $null : (Get-EdgeBackupSyncRoot -SyncRoot $SyncRoot)
                $canTombstone = $syncRootPath -and (Test-Path -LiteralPath (Join-Path $syncRootPath 'store') -PathType Container) -and
                    (Get-Command -Name Set-EdgeSyncTombstone -ErrorAction Ignore)

                foreach ($p in $confirmed) {
                    $isOrphan = [bool]($p.PSObject.Properties['IsOrphan'] -and $p.IsOrphan)
                    try {
                        Remove-EdgeLocalProfile -Directory $p.Directory -Channel $ch -UserDataRoot $UserDataRoot -Permanent:$Permanent -Confirm:$false -WhatIf:$false
                    }
                    catch {
                        Write-EdgeSyncLog -Message "Removing Edge $ch profile '$($p.Name)' ($($p.Directory)) failed: $($_.Exception.Message)" -Level Warning
                        & $addResult $p 'Error' $_.Exception.Message $backupPath $false
                        continue
                    }
                    $tomb = $false
                    if ($canTombstone -and -not $isOrphan) {
                        try {
                            Set-EdgeSyncTombstone -SyncRoot $syncRootPath -Channel $ch -ProfileKey $p.Key -Name $p.Name
                            $tomb = $true
                        }
                        catch { Write-EdgeSyncLog -Message "Tombstone for '$($p.Key)' failed: $($_.Exception.Message)" -Level Warning }
                    }
                    Write-EdgeSyncLog -Message "Removed Edge $ch profile '$($p.Name)' ($($p.Directory))$($Permanent ? ' permanently' : ' to the Recycle Bin')$($backupPath ? "; backup: $backupPath" : '')." -Level Info
                    & $addResult $p 'Removed' $null $backupPath $tomb
                }
            }

            $removed = @($results | Where-Object Action -eq 'Removed')
            if ($removed) {
                $where = $Permanent ? 'deleted' : 'moved to the Recycle Bin'
                Write-Host "Edge ${ch}: $($removed.Count) profile(s) removed ($where)$($removed[0].BackupPath ? "; backup: $($removed[0].BackupPath)" : '')."
            }
            if ($PassThru) { $results }
        }
    }
}
