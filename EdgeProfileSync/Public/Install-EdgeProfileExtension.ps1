function Install-EdgeProfileExtension {
    <#
    .SYNOPSIS
        Opens the store pages of extensions that still have to be installed in a profile.

    .DESCRIPTION
        After a restore or sync from another machine, extensions cannot be installed silently: Edge
        protects its extension registration with machine-bound MACs. The restore/sync therefore keeps
        a "pending" list per profile. This command re-checks that list against the extensions that
        are installed now (installed ones are removed from the list) and opens the remaining store
        pages in the right profile ("msedge.exe --profile-directory=..."), so you only have to click
        "Get" / "Add to Chrome" for each. The extension's settings are applied by the next
        Sync-EdgeProfiles run, or were already restored by Restore-EdgeProfiles.

        Chrome Web Store extensions need "Allow extensions from other stores" to be switched on once
        in Edge. Unpacked or self-hosted extensions are only listed.

        This is an interactive command; the scheduled sync task never runs it.

    .PARAMETER Channel
        Edge channel(s). Default: Stable.

    .PARAMETER Profile
        Only these profiles (display name, key or folder name; wildcards allowed). Default: all
        profiles with pending extensions.

    .PARAMETER PassThru
        Return one object per pending extension with the action taken.

    .EXAMPLE
        Install-EdgeProfileExtension

    .EXAMPLE
        Install-EdgeProfileExtension -Profile Work -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string[]]$Channel = @('Stable'),

        [Alias('Profile')]
        [SupportsWildcards()]
        [string[]]$ProfileName,

        [switch]$PassThru,

        [Parameter(DontShow)]
        [string]$UserDataRoot
    )

    $anyPending = $false
    foreach ($ch in $Channel) {
        $pendingAll = @(Get-EdgePendingExtension -Channel $ch)
        if (-not $pendingAll) { continue }
        $localProfiles = @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $UserDataRoot)

        foreach ($group in ($pendingAll | Group-Object ProfileKey)) {
            $key = $group.Name
            $prof = $localProfiles | Where-Object Key -eq $key | Select-Object -First 1
            if (-not $prof) {
                if (-not $ProfileName -or ($ProfileName | Where-Object { $key -like $_ })) {
                    Write-Warning "Edge ${ch}: profile '$key' has pending extensions but does not exist locally; skipped."
                }
                continue
            }
            if (-not (Select-EdgeProfileByFilter -InputObject @($prof) -Filter $ProfileName)) { continue }

            # Drop what has been installed in the meantime.
            $installed = @(Get-EdgeExtensionInventory -ProfilePath $prof.Path | ForEach-Object { $_.Id })
            $still = @($group.Group | Where-Object Id -notin $installed)
            foreach ($done in @($group.Group | Where-Object Id -in $installed)) {
                if ($PassThru) { New-EdgeExtensionInstallResult $ch $prof $done 'AlreadyInstalled' }
            }
            if ($still.Count -ne $group.Count -and $PSCmdlet.ShouldProcess("$ch\$key", 'Update pending extension list')) {
                Set-EdgePendingExtension -Channel $ch -ProfileKey $key -Extension $still -WhatIf:$false -Confirm:$false
            }
            if (-not $still) { continue }
            $anyPending = $true

            $storeItems = @($still | Where-Object { $_.StoreUrl -and $_.Source -in 'EdgeStore', 'ChromeStore' })
            $manualItems = @($still | Where-Object { $_ -notin $storeItems })

            Write-Host "Profile '$($prof.Name)' ($($prof.Directory)): $($still.Count) extension(s) to install."
            foreach ($m in $manualItems) {
                Write-Host "  - $($m.Name) [$($m.Id)] ($($m.Source)): not available in a store, install it manually."
                if ($PassThru) { New-EdgeExtensionInstallResult $ch $prof $m 'Manual' }
            }
            if (-not $storeItems) { continue }
            if ($storeItems | Where-Object Source -eq 'ChromeStore') {
                Write-Host '  Note: Chrome Web Store extensions need "Allow extensions from other stores" (shown on the store page) to be enabled once.'
            }

            $urls = @($storeItems | ForEach-Object { $_.StoreUrl })
            if ($PSCmdlet.ShouldProcess("Edge $ch profile '$($prof.Name)'", "Open $($urls.Count) store page(s)")) {
                $exe = Get-EdgeExecutablePath -Channel $ch
                if (-not $exe) {
                    Write-Warning "msedge.exe for Edge $ch not found. Open these pages in profile '$($prof.Name)':"
                    $urls | ForEach-Object { Write-Host "    $_" }
                    $action = 'NotOpened'
                }
                else {
                    $argList = @("--profile-directory=`"$($prof.Directory)`"") + $urls
                    Start-Process -FilePath $exe -ArgumentList $argList
                    foreach ($s in $storeItems) { Write-Host "  - $($s.Name): $($s.StoreUrl)" }
                    $action = 'Opened'
                }
            }
            else { $action = 'WhatIf' }
            if ($PassThru) { foreach ($s in $storeItems) { New-EdgeExtensionInstallResult $ch $prof $s $action } }
        }
    }
    if (-not $anyPending) { Write-Host 'No pending extensions.' }
}
