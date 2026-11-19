# Core helpers: copying, fingerprinting and moving files/directories.

function Copy-EdgeItem {
    <#
    .SYNOPSIS
        Copies a file (overwrite, keeps LastWriteTimeUtc, retries on IOException) or mirrors a directory
        with robocopy (/MIR; exit code >= 8 throws). Returns nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [switch]$Directory
    )

    if ($Directory) {
        if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
            throw "Source directory not found: $Source"
        }
        $src = $Source.TrimEnd('\')
        $dst = $Destination.TrimEnd('\')
        $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'
        if (-not (Test-Path -LiteralPath $robo)) { $robo = 'robocopy.exe' }
        $output = & $robo $src $dst /MIR /R:2 /W:1 /MT:8 /NJH /NJS /NP /NFL /NDL 2>&1
        $code = $LASTEXITCODE
        if ($code -ge 8) {
            $detail = (@($output) | Where-Object { "$_".Trim() } | Select-Object -Last 5) -join ' '
            throw "robocopy '$src' -> '$dst' failed with exit code $code. $detail"
        }
        $global:LASTEXITCODE = 0
        return
    }

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Source file not found: $Source"
    }
    $parent = Split-Path -Path $Destination -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }

    $lastWrite = [IO.File]::GetLastWriteTimeUtc($Source)
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            try {
                [IO.File]::Copy($Source, $Destination, $true)
            }
            catch [System.IO.IOException] {
                # Edge may hold the file open without read sharing for CopyFile; a shared read usually works.
                $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try {
                    $out = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $in.CopyTo($out) } finally { $out.Dispose() }
                }
                finally { $in.Dispose() }
            }
            [IO.File]::SetLastWriteTimeUtc($Destination, $lastWrite)
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge $maxAttempts) {
                throw "Copy '$Source' -> '$Destination' failed after $maxAttempts attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
}

function Test-EdgeSqliteJournalHot {
    # Internal: $true when a rollback journal exists with a valid header (a write transaction is in flight).
    # In exclusive locking mode SQLite keeps the journal file but zeroes its header after commit.
    param([string]$JournalPath)
    if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) { return $false }
    try {
        $fs = [IO.File]::Open($JournalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            if ($fs.Length -lt 8) { return $false }
            $buf = [byte[]]::new(8)
            $null = $fs.Read($buf, 0, 8)
            # SQLite journal magic: d9 d5 05 f9 20 a1 63 d7
            return [Convert]::ToHexString($buf) -eq 'D9D505F920A163D7'
        }
        finally { $fs.Dispose() }
    }
    catch { return $true }
}

function Copy-EdgeSqliteSnapshot {
    <#
    .SYNOPSIS
        Copies a SQLite database that Edge may have open, so the copy is a committed, consistent state.
    .DESCRIPTION
        Waits until no write transaction is in flight (no hot rollback journal), copies the database with
        shared read access and verifies that it did not change during the copy (length + LastWriteTimeUtc,
        journal still not hot). Retries up to -MaxAttempts times. A '-wal' file (WAL mode) is copied along
        as "<Destination>-wal" so SQLite replays it when the copy is opened; a stale destination '-wal' is
        removed. Throws when no stable copy could be made.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [int]$MaxAttempts = 10
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Source file not found: $Source" }
    $journal = "$Source-journal"
    $wal = "$Source-wal"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (Test-EdgeSqliteJournalHot -JournalPath $journal) {
            Start-Sleep -Milliseconds 300
            continue
        }
        $before = [IO.FileInfo]::new($Source)
        $beforeState = '{0}|{1}' -f $before.Length, $before.LastWriteTimeUtc.Ticks
        try {
            Copy-EdgeItem -Source $Source -Destination $Destination
            if (Test-Path -LiteralPath $wal -PathType Leaf) {
                Copy-EdgeItem -Source $wal -Destination "$Destination-wal"
            }
            elseif (Test-Path -LiteralPath "$Destination-wal") {
                Remove-Item -LiteralPath "$Destination-wal" -Force
            }
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Milliseconds 300
            continue
        }
        $after = [IO.FileInfo]::new($Source)
        $afterState = '{0}|{1}' -f $after.Length, $after.LastWriteTimeUtc.Ticks
        if ($beforeState -eq $afterState -and -not (Test-EdgeSqliteJournalHot -JournalPath $journal)) {
            return
        }
        Start-Sleep -Milliseconds 300
    }
    throw "Could not take a stable snapshot of '$Source' after $MaxAttempts attempts (database kept changing)."
}

function Get-EdgeItemFingerprint {
    <#
    .SYNOPSIS
        File: SHA256 hex (lowercase) of the content. Directory: SHA256 over sorted
        "relpath|length|lastwriteutc ticks" lines. Missing path: $null.
    .DESCRIPTION
        Directory timestamps are truncated to whole seconds so that copies through OneDrive or file
        systems with coarser timestamps still produce identical fingerprints. Relative paths use '\'
        and are sorted ordinal-ignore-case, so the result is the same on every machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($fs)).ToLowerInvariant()
        }
        finally { $fs.Dispose() }
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $dirInfo = [IO.DirectoryInfo]::new($root)
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $dirInfo.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
            $rel = $f.FullName.Substring($root.Length + 1)
            $ticks = $f.LastWriteTimeUtc.Ticks
            $ticks -= $ticks % [TimeSpan]::TicksPerSecond
            $lines.Add(('{0}|{1}|{2}' -f $rel, $f.Length, $ticks))
        }
        $lines.Sort([StringComparer]::OrdinalIgnoreCase)
        $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }

    $null
}

function Move-EdgeItemAside {
    <#
    .SYNOPSIS
        Moves a file or directory (if it exists) into BackupRoot, keeping its name; adds ".1", ".2", ...
        when the name is taken. Never deletes. -PassThru returns the new path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$BackupRoot,

        [switch]$PassThru
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        $null = New-Item -Path $BackupRoot -ItemType Directory -Force
    }

    $name = Split-Path -Path $Path -Leaf
    $target = Join-Path $BackupRoot $name
    $i = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $BackupRoot ('{0}.{1}' -f $name, $i)
        $i++
    }

    if (-not $PSCmdlet.ShouldProcess($Path, "Move aside to '$target'")) { return }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Move-Item -LiteralPath $Path -Destination $target -ErrorAction Stop
            break
        }
        catch {
            if ($attempt -ge 3) { throw "Could not move '$Path' to '$target': $($_.Exception.Message)" }
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }

    if ($PassThru) { $target }
}
