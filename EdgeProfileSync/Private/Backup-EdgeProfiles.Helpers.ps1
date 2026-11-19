# Internal helpers for Backup-EdgeProfiles (not exported).

$script:EdgeFullBackupExcludeDirs = @(
    'Cache', 'Code Cache', 'GPUCache', 'CacheStorage', 'ScriptCache', 'ShaderCache', 'GrShaderCache',
    'GraphiteDawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'DawnCache', 'Media Cache',
    'Crashpad', 'BrowserMetrics', 'Crash Reports', 'component_crx_cache', 'extensions_crx_cache',
    'optimization_guide_hint_cache_store', 'optimization_guide_model_store', 'optimization_guide_prediction_model_downloads',
    'OptimizationHints', 'OnDeviceHeadSuggestModel', 'Safe Browsing', 'SafetyTips', 'Subresource Filter',
    'Trust Protection Lists', 'WidevineCdm', 'screen_ai', 'MEIPreload', 'hyphen-data', 'ZxcvbnData',
    'FileTypePolicies', 'CertificateRevocation', 'Crowd Deny', 'OriginTrials', 'PKIMetadata', 'SSLErrorAssistant',
    'TpcdMetadata', 'Speech Recognition', 'ProbabilisticRevealTokenRegistry', 'Snapshots', 'GraphiteCache',
    'Edge Shopping', 'EdgeCoupons', 'Edge Travel', 'Edge Wallet Assets', 'ml_models', 'Smartscreen', 'BrowserMetrics*'
)

$script:EdgeFullBackupExcludeFiles = @(
    '*.pma', 'LOCK', 'lockfile', 'SingletonLock', 'SingletonCookie', 'SingletonSocket', '*.tmp', 'BrowserMetrics*',
    'CrashpadMetrics*', 'Last Browser', 'Last Version'
)

function Get-EdgeDefaultBackupDestination {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$MachineId)

    $root = $null
    if (Get-Command -Name Get-EdgeProfileSyncConfig -ErrorAction Ignore) {
        try { $root = (Get-EdgeProfileSyncConfig).SyncRoot } catch { Write-Verbose "Get-EdgeProfileSyncConfig failed: $($_.Exception.Message)" }
    }
    if (-not $root) {
        $oneDrive = $env:OneDriveCommercial ? $env:OneDriveCommercial : $env:OneDrive
        if (-not $oneDrive) { throw 'No -Destination given and no OneDrive folder found; specify -Destination.' }
        $root = Join-Path $oneDrive 'EdgeProfileSync'
    }
    Join-Path $root "backups\$MachineId"
}

function Copy-EdgeCategoryToStage {
    # Copies one category of a profile into StagePath. Returns $true when anything was staged.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][object]$Category,
        [Parameter(Mandatory)][string]$StagePath
    )
    $any = $false
    if ($Category.Generated) {
        if ($Category.Name -eq 'ExtensionList') {
            $inventory = @(Get-EdgeExtensionInventory -ProfilePath $ProfilePath)
            $null = New-Item -ItemType Directory -Path $StagePath -Force
            Write-EdgeJsonFile -Path (Join-Path $StagePath $Category.Generated) -InputObject @{
                GeneratedUtc = [datetime]::UtcNow.ToString('o')
                Extensions   = @($inventory)
            }
            return $true
        }
        Write-Verbose "No generator for category '$($Category.Name)'."
        return $false
    }
    if ($Category.PerExtension) {
        # "<StagePath>\<id>\<dir>\..." for every installed (non-component) extension that has data.
        foreach ($ext in @(Get-EdgeExtensionInventory -ProfilePath $ProfilePath)) {
            foreach ($d in $Category.Directories) {
                $src = Join-Path $ProfilePath (Join-Path $d $ext.Id)
                if (Test-Path -LiteralPath $src -PathType Container) {
                    Copy-EdgeItem -Source $src -Destination (Join-Path $StagePath (Join-Path $ext.Id $d)) -Directory
                    $any = $true
                }
            }
        }
        return $any
    }
    foreach ($f in $Category.Files) {
        $src = Join-Path $ProfilePath $f
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            if ($Category.Sqlite) { Copy-EdgeSqliteSnapshot -Source $src -Destination (Join-Path $StagePath $f) }
            else { Copy-EdgeItem -Source $src -Destination (Join-Path $StagePath $f) }
            $any = $true
        }
    }
    foreach ($d in $Category.Directories) {
        $src = Join-Path $ProfilePath $d
        if (Test-Path -LiteralPath $src -PathType Container) {
            $dst = Join-Path $StagePath $d
            Copy-EdgeItem -Source $src -Destination $dst -Directory
            if ($Category.Sqlite) {
                # Re-copy the databases inside the directory as consistent snapshots.
                foreach ($db in @(Get-ChildItem -LiteralPath $src -File -Recurse -Force -ErrorAction Ignore)) {
                    if ($db.Name -notlike '*.db' -and $db.Name -notlike '*SQLite*') { continue }
                    if ($db.Name -match '-(journal|wal|shm)$') { continue }
                    $rel = [System.IO.Path]::GetRelativePath($src, $db.FullName)
                    Copy-EdgeSqliteSnapshot -Source $db.FullName -Destination (Join-Path $dst $rel)
                }
            }
            $any = $true
        }
    }
    $any
}

function Invoke-EdgeRobocopy {
    # robocopy wrapper for -Full backup/restore. Locked files (Edge running) are reported, not fatal.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirectory,
        [string[]]$ExcludeFile,
        [switch]$Mirror
    )
    $rcArgs = @($Source, $Destination, ($Mirror ? '/MIR' : '/E'), '/R:1', '/W:1', '/MT:16', '/XJ', '/NJH', '/NJS', '/NP', '/NFL', '/NDL')
    if ($ExcludeDirectory) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirectory }
    if ($ExcludeFile) { $rcArgs += '/XF'; $rcArgs += $ExcludeFile }
    $output = & robocopy.exe @rcArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ge 16) { throw "robocopy '$Source' -> '$Destination' failed (exit $code): $($output -join ' ')" }
    if ($code -ge 8) {
        Write-Warning "Some files could not be copied from '$Source' (probably locked by Edge; exit $code)."
        Write-Verbose ($output -join [Environment]::NewLine)
    }
    $global:LASTEXITCODE = 0
}

function Export-EdgeRegistryKey {
    # reg.exe export; returns $true on success, $false when the key does not exist.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Path
    )
    $psKey = 'Registry::' + ($Key -replace '^HKCU\\', 'HKEY_CURRENT_USER\')
    if (-not (Test-Path -LiteralPath $psKey)) {
        Write-Verbose "Registry key $Key not found; not exported."
        return $false
    }
    $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
    $null = & reg.exe export $Key $Path /y 2>&1
    $ok = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if (-not $ok) { Write-Warning "reg.exe export of $Key failed." }
    $ok
}
