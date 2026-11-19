# Internal helpers for Restore-EdgeProfiles (not exported).

function Expand-EdgeZipToDirectory {
    <#
    .SYNOPSIS
        Extracts a zip entry by entry with a byte-based progress bar (equivalent to
        ZipFile.ExtractToDirectory, including the path traversal check). Returns a summary object
        (Files, Bytes, IsV2 = the zip contains backup-manifest.json, Duration).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination,
        [int]$ProgressId = 1,
        [string]$Activity = 'Extracting backup'
    )
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $null = [System.IO.Directory]::CreateDirectory($root)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $progress = $null
    try {
        $entries = @($zip.Entries)
        [long]$total = 0
        foreach ($e in $entries) { $total += $e.Length }
        $isV2 = $null -ne $zip.GetEntry('backup-manifest.json')
        $progress = New-EdgeProgress -Activity $Activity -Total $total -Id $ProgressId
        $files = 0
        $i = 0
        foreach ($e in $entries) {
            $i++
            $dest = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $e.FullName))
            if (-not $dest.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase) -and $dest -ne $root) {
                throw "Zip entry '$($e.FullName)' would extract outside the destination folder."
            }
            if (-not $e.Name) {
                # directory entry
                $null = [System.IO.Directory]::CreateDirectory($dest)
                continue
            }
            Update-EdgeProgress -Progress $progress -Status ('File {0} of {1}' -f $i, $entries.Count) -CurrentOperation $e.FullName
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dest))
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
            $files++
            Update-EdgeProgress -Progress $progress -Add $e.Length
        }
        $sw.Stop()
        [pscustomobject]@{ Files = $files; Bytes = $total; IsV2 = $isV2; Duration = $sw.Elapsed }
    }
    finally {
        $zip.Dispose()
        if ($progress) { Complete-EdgeProgress -Progress $progress }
    }
}

function Assert-EdgeRestoreAllowed {
    # Stops Edge when -CloseEdge. Returns $true when Edge of the channel is (still) running.
    # With -RequireClosed a running Edge is an error (under -WhatIf only a warning).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [switch]$CloseEdge,
        [switch]$RequireClosed,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet
    )
    $state = Get-EdgeProcessState -Channel $Channel
    if (-not $state.Running) { return $false }
    if ($CloseEdge) {
        if ($Cmdlet.ShouldProcess("Edge $Channel", 'Stop')) {
            if (-not (Stop-EdgeProcess -Channel $Channel)) { throw "Edge $Channel could not be stopped; restore aborted." }
            return $false
        }
        return $true
    }
    if (-not $RequireClosed) { return $true }
    if ($WhatIfPreference) { Write-Warning "Edge $Channel is running; a real restore needs -CloseEdge or Edge closed."; return $true }
    throw "Edge $Channel is running. This restore replaces the whole User Data folder and needs Edge closed (also check the system tray / Startup Boost), or use -CloseEdge."
}

function Move-EdgeUserDataAside {
    # Rename/Remove: renames User Data to "User Data-<timestamp>". Returns the new path, or $null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserDataPath,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Timestamp,
        [switch]$Force,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet
    )
    if ($Action -in 'Merge', 'Replace' -or -not (Test-Path -LiteralPath $UserDataPath -PathType Container)) { return $null }
    if ($Action -eq 'Remove' -and -not $Force -and -not $WhatIfPreference) {
        if (-not $Cmdlet.ShouldContinue("The existing Edge data in '$UserDataPath' (all profiles, passwords, cookies) will be DELETED after the restore. Continue?", 'Remove existing Edge User Data')) {
            Write-Warning 'Restore cancelled.'
            return $null
        }
    }
    $newPath = "$UserDataPath-$Timestamp"
    if (-not $Cmdlet.ShouldProcess($UserDataPath, "Rename to '$(Split-Path $newPath -Leaf)'")) { return $null }
    # Antivirus or the search indexer can briefly hold freshly written files; retry before giving up.
    for ($attempt = 1; ; $attempt++) {
        try {
            Rename-Item -LiteralPath $UserDataPath -NewName (Split-Path $newPath -Leaf) -ErrorAction Stop
            break
        }
        catch {
            if ($attempt -ge 5) { throw }
            Start-Sleep -Milliseconds (400 * $attempt)
        }
    }
    $newPath
}

function Initialize-EdgeRestoreLocalState {
    # Creates a fresh User Data folder with a Local State that registers the backup profiles
    # under their original folder names.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserDataPath,
        [Parameter(Mandatory)][object[]]$Profile,
        [bool]$SameMachine
    )
    $null = New-Item -ItemType Directory -Path $UserDataPath -Force
    $localStatePath = Join-Path $UserDataPath 'Local State'
    if (Test-Path -LiteralPath $localStatePath) { return }

    $infoCache = [ordered]@{}
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($bp in $Profile) {
        $dir = [string]$bp['Directory']
        $entry = [ordered]@{}
        $src = $bp['InfoCache']
        if ($src -is [System.Collections.IDictionary]) {
            foreach ($k in $src.Keys) {
                $ks = [string]$k
                if (-not $SameMachine) {
                    # Account fields would show a signed-in profile without tokens on another machine.
                    if ($ks -in $script:EdgeAccountInfoFields -or $ks -like 'edge_account*' -or $ks -like 'signin*') { continue }
                }
                $entry[$ks] = $src[$k]
            }
        }
        $entry['name'] = [string]$bp['Name']
        $infoCache[$dir] = $entry
        $order.Add($dir)
        $null = New-Item -ItemType Directory -Path (Join-Path $UserDataPath $dir) -Force
    }
    Write-EdgeJsonFile -Path $localStatePath -InputObject ([ordered]@{
            profile = [ordered]@{
                info_cache     = $infoCache
                profiles_order = $order.ToArray()
                last_used      = $order[0]
            }
        })
}

function Restore-EdgeCategoryFromStage {
    # Copies one staged category into a profile. Existing files that get replaced, plus the
    # category's MoveAsideOnRestore files, are moved into ReplacedRoot first (never deleted).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StagePath,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][object]$Category,
        [Parameter(Mandatory)][string]$ReplacedRoot
    )
    if ($Category.PerExtension) {
        # "<StagePath>\<id>\<dir>\..." -> "<profile>\<dir>\<id>\..."
        foreach ($idDir in @(Get-ChildItem -LiteralPath $StagePath -Directory)) {
            foreach ($d in $Category.Directories) {
                $src = Join-Path $idDir.FullName $d
                if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }
                $dst = Join-Path $ProfilePath (Join-Path $d $idDir.Name)
                Move-EdgeItemAside -Path $dst -BackupRoot (Join-Path $ReplacedRoot $d) -WhatIf:$false -Confirm:$false
                Copy-EdgeItem -Source $src -Destination $dst -Directory
            }
        }
        return
    }

    $items = @(Get-ChildItem -LiteralPath $StagePath -Force)
    foreach ($name in @($items | ForEach-Object { $_.Name }) + @($Category.MoveAsideOnRestore)) {
        if (-not $name) { continue }
        Move-EdgeItemAside -Path (Join-Path $ProfilePath $name) -BackupRoot $ReplacedRoot -WhatIf:$false -Confirm:$false
    }
    foreach ($item in $items) {
        $dst = Join-Path $ProfilePath $item.Name
        if ($item.PSIsContainer) { Copy-EdgeItem -Source $item.FullName -Destination $dst -Directory }
        else { Copy-EdgeItem -Source $item.FullName -Destination $dst }
    }
}

function Update-EdgePendingFromBackup {
    # Compares a backup's extensions.json with the profile's installed extensions, prints the missing
    # ones with store links and stores them in the pending list. Returns the missing extensions.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InventoryFile,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$ProfileKey,
        [Parameter(Mandatory)][string]$ProfilePath,
        [string]$ProfileName,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet
    )
    $data = Read-EdgeJsonFile -Path $InventoryFile
    $backupExt = @($data -is [System.Collections.IDictionary] ? $data['Extensions'] : $data) | Where-Object { $_ -is [System.Collections.IDictionary] }
    $installed = @(Get-EdgeExtensionInventory -ProfilePath $ProfilePath | ForEach-Object { $_.Id })

    # Policy-installed extensions come back by themselves; component ones are never in the inventory.
    $missing = @($backupExt | Where-Object { $_['Id'] -notin $installed -and $_['Source'] -ne 'Policy' } | ForEach-Object {
            [pscustomobject]@{
                Id = [string]$_['Id']; Name = [string]$_['Name']; Version = [string]$_['Version']
                Source = [string]$_['Source']; StoreUrl = $_['StoreUrl']
            }
        })

    # Keep earlier pending entries that are still not installed.
    $previous = @(Get-EdgePendingExtension -Channel $Channel -ProfileKey $ProfileKey | Where-Object { $_.Id -notin $installed -and $_.Id -notin @($missing | ForEach-Object { $_.Id }) })
    $pending = @($missing) + @($previous)

    if ($missing) {
        Write-EdgeStatus "      Profile '$ProfileName': $($missing.Count) extension(s) from the backup are not installed:" -Level Warning
        foreach ($m in $missing) {
            $where = $m.StoreUrl ? $m.StoreUrl : "($($m.Source): not available in a store, install manually)"
            Write-EdgeStatus "        - $($m.Name) [$($m.Id)] $where" -Level Step
        }
        Write-EdgeStatus "        Run 'Install-EdgeProfileExtension -Profile ""$ProfileKey""' to open the store pages; their data is applied once installed." -Level Step
    }
    if ($Cmdlet.ShouldProcess("$Channel\$ProfileKey", 'Update pending extension list')) {
        Set-EdgePendingExtension -Channel $Channel -ProfileKey $ProfileKey -Extension $pending -WhatIf:$false -Confirm:$false
    }
    $missing
}

function Import-EdgeRegistryFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $out = & reg.exe import $Path 2>&1
    $ok = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if (-not $ok) { Write-Warning "reg.exe import of '$Path' failed: $($out -join ' ')" }
}

function Clear-EdgeUnprotectedProfile {
    <#
    .SYNOPSIS
        -ExistingDataAction Replace: moves every local profile that is not protected into
        "<User Data>\EdgeProfileSync-replaced\<timestamp>\profiles\<Directory>" and unregisters it from
        Local State. Protected profiles (Default, signed in) and Local State itself stay. Edge must be closed.
        Returns the moved profiles.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$UserDataRoot,
        [Parameter(Mandatory)][string]$Timestamp,
        [switch]$IncludeProtectedProfiles,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet
    )
    $local = @(Get-EdgeLocalProfile -Channel $Channel -UserDataRoot $UserDataRoot)
    $toMove = @($local | Where-Object { $IncludeProtectedProfiles -or -not (Test-EdgeProtectedProfile $_) } | Where-Object Directory -ne 'Default')
    $keep = @($local | Where-Object { $_.Directory -notin @($toMove | ForEach-Object { $_.Directory }) })
    if (-not $toMove) {
        Write-EdgeNote 'Replace: no local profiles to move aside.' -Level Info
        return
    }
    Write-EdgeNote ('Replace: moving {0} local profile(s) aside; keeping {1}.' -f $toMove.Count,
        ($keep ? (($keep | ForEach-Object { "$($_.Name) ($($_.Directory))" }) -join ', ') : 'none')) -Level Info
    $aside = Join-Path $UserDataRoot "EdgeProfileSync-replaced\$Timestamp\profiles"
    foreach ($p in $toMove) {
        if (-not $Cmdlet.ShouldProcess("$($p.Path) ('$($p.Name)')", 'Move profile aside (Replace)')) { continue }
        Remove-EdgeLocalProfile -Directory $p.Directory -Channel $Channel -UserDataRoot $UserDataRoot -KeepFolder -Confirm:$false
        Move-EdgeItemAside -Path $p.Path -BackupRoot $aside -WhatIf:$false -Confirm:$false
        $p
    }
    Write-EdgeNote "Replace: the previous profiles are kept in '$aside' (delete it when everything works)."
}
