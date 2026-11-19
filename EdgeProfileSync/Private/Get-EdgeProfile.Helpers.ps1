# Internal helpers for Get-EdgeProfile (not exported).

function Get-EdgeBackupSyncRoot {
    # Sync root from -SyncRoot or the module config; $null when unavailable.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$SyncRoot)
    if ($SyncRoot) { return $SyncRoot }
    if (Get-Command -Name Get-EdgeProfileSyncConfig -ErrorAction Ignore) {
        try { return [string](Get-EdgeProfileSyncConfig).SyncRoot } catch { Write-Verbose "Get-EdgeProfileSyncConfig failed: $($_.Exception.Message)" }
    }
    $null
}

function Get-EdgeBookmarkCount {
    # Number of url nodes in a Bookmarks JSON file (0 when missing or unreadable).
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    try { $json = Read-EdgeJsonFile -Path $Path } catch { return 0 }
    if ($json -isnot [System.Collections.IDictionary] -or $json['roots'] -isnot [System.Collections.IDictionary]) { return 0 }
    $count = 0
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($r in $json['roots'].Values) { $stack.Push($r) }
    while ($stack.Count) {
        $node = $stack.Pop()
        if ($node -isnot [System.Collections.IDictionary]) { continue }
        if ($node['type'] -eq 'url' -or ($node['url'] -and -not $node['children'])) { $count++ }
        foreach ($c in @($node['children'])) { if ($null -ne $c) { $stack.Push($c) } }
    }
    $count
}

function Get-EdgeOrphanProfile {
    # Profile folders on disk (they contain 'Preferences') that are not registered in Local State.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserDataPath,
        [Parameter(Mandatory)][string]$Channel,
        [AllowEmptyCollection()][object[]]$Registered
    )
    if (-not (Test-Path -LiteralPath $UserDataPath -PathType Container)) { return }
    $known = @($Registered | ForEach-Object { $_.Directory })
    foreach ($dir in @(Get-ChildItem -LiteralPath $UserDataPath -Directory -ErrorAction Ignore)) {
        if ($dir.Name -in $known -or $dir.Name -in 'System Profile', 'Guest Profile') { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'Preferences') -PathType Leaf)) { continue }
        [pscustomobject]@{
            Channel       = $Channel
            Directory     = $dir.Name
            Path          = $dir.FullName
            Name          = '(orphan)'
            Key           = $dir.Name
            IsSignedIn    = $false
            Account       = ''
            LastActiveUtc = $dir.LastWriteTimeUtc
            InfoCache     = @{}
            IsOrphan      = $true
        }
    }
}

function Resolve-EdgeBackupCategory {
    # Returns category objects (Get-EdgeDataCategory) for the given names; empty = defaults, 'All' = all.
    [CmdletBinding()]
    param([string[]]$Category)

    if (-not $Category) { return @(Get-EdgeDataCategory -DefaultOnly) }
    if ($Category -contains 'All') { return @(Get-EdgeDataCategory) }
    $known = @(Get-EdgeDataCategoryName)
    $unknown = @($Category | Where-Object { $_ -notin $known })
    if ($unknown) {
        throw "Unknown category: $($unknown -join ', '). Valid: $($known -join ', '), All."
    }
    @(Get-EdgeDataCategory -Name $Category)
}

function Select-EdgeProfileByFilter {
    # Filters profile objects (anything with Name/Key/Directory) by wildcard patterns; no filter = all.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$InputObject,
        [string[]]$Filter,
        [string[]]$Property = @('Name', 'Key', 'Directory')
    )
    foreach ($p in $InputObject) {
        if (-not $p) { continue }
        if (-not $Filter) { $p; continue }
        $values = foreach ($prop in $Property) {
            if ($p -is [System.Collections.IDictionary]) { $p[$prop] } else { $p.PSObject.Properties[$prop]?.Value }
        }
        $hit = $false
        foreach ($f in $Filter) {
            foreach ($v in $values) { if ($v -and $v -like $f) { $hit = $true; break } }
            if ($hit) { break }
        }
        if ($hit) { $p }
    }
}
