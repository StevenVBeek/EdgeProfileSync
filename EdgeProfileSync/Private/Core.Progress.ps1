# Core helpers: progress bars and console status lines for long-running commands.
#
# Progress is tracked in bytes (or steps) so the bar can show a percentage, throughput and an ETA.
# Console lines go through Write-Host (information stream 6), so callers and tests can silence them
# with 6>$null, and every command honours $script:EdgeQuiet (set by -Quiet runs such as the task).

$script:EdgeQuiet = $false

function New-EdgeProgress {
    <#
    .SYNOPSIS
        Creates a progress tracker. -Total is the amount of work (bytes or steps), -Unit 'Bytes' or 'Steps'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Activity,
        [long]$Total = 0,
        [ValidateSet('Bytes', 'Steps')][string]$Unit = 'Bytes',
        [int]$Id = 1,
        [int]$ParentId = -1
    )
    [pscustomobject]@{
        Activity     = $Activity
        Total        = [long][Math]::Max([long]0, $Total)
        Done         = [long]0
        Unit         = $Unit
        Id           = $Id
        ParentId     = $ParentId
        Stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()
        LastRenderMs = [long]-1000
    }
}

function Format-EdgeSize {
    # Internal: human readable size.
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    '{0:N0} B' -f $Bytes
}

function Format-EdgeDuration {
    # Internal: 1h 02m / 3m 05s / 12.4 s.
    param([TimeSpan]$Duration)
    if ($Duration.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][Math]::Floor($Duration.TotalHours), $Duration.Minutes }
    if ($Duration.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [int][Math]::Floor($Duration.TotalMinutes), $Duration.Seconds }
    '{0:N1} s' -f $Duration.TotalSeconds
}

function Update-EdgeProgress {
    <#
    .SYNOPSIS
        Advances a tracker (-Add) or sets it (-Done) and redraws the bar: percentage, done/total, speed, ETA.
        Redraws at most every 150 ms unless -Force.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Progress,
        [string]$Status,
        [string]$CurrentOperation,
        [long]$Add = 0,
        [long]$Done = -1,
        [switch]$Force
    )
    if ($Done -ge 0) { $Progress.Done = $Done } else { $Progress.Done += $Add }
    if ($script:EdgeQuiet) { return }

    $elapsedMs = $Progress.Stopwatch.ElapsedMilliseconds
    if (-not $Force -and ($elapsedMs - $Progress.LastRenderMs) -lt 150) { return }
    $Progress.LastRenderMs = $elapsedMs

    $pct = 0
    $secondsRemaining = -1
    $detail = ''
    if ($Progress.Total -gt 0) {
        $doneClamped = [Math]::Min($Progress.Done, $Progress.Total)
        $pct = [int][Math]::Floor(100.0 * $doneClamped / $Progress.Total)
        $elapsed = $Progress.Stopwatch.Elapsed.TotalSeconds
        if ($doneClamped -gt 0 -and $elapsed -ge 1) {
            $rate = $doneClamped / $elapsed
            if ($rate -gt 0) { $secondsRemaining = [int][Math]::Ceiling(($Progress.Total - $doneClamped) / $rate) }
            if ($Progress.Unit -eq 'Bytes') {
                $detail = '{0} of {1} - {2}/s' -f (Format-EdgeSize $doneClamped), (Format-EdgeSize $Progress.Total), (Format-EdgeSize $rate)
            }
        }
        elseif ($Progress.Unit -eq 'Bytes') {
            $detail = '{0} of {1}' -f (Format-EdgeSize $doneClamped), (Format-EdgeSize $Progress.Total)
        }
        if ($Progress.Unit -eq 'Steps') { $detail = '{0} of {1}' -f $doneClamped, $Progress.Total }
    }

    $statusText = (@($Status, $detail) | Where-Object { $_ }) -join ' | '
    $params = @{
        Id              = $Progress.Id
        Activity        = $Progress.Activity
        Status          = $statusText ? $statusText : 'Working...'
        PercentComplete = $pct
    }
    if ($secondsRemaining -ge 0) { $params.SecondsRemaining = $secondsRemaining }
    if ($CurrentOperation) { $params.CurrentOperation = $CurrentOperation }
    if ($Progress.ParentId -ge 0) { $params.ParentId = $Progress.ParentId }
    Write-Progress @params
}

function Complete-EdgeProgress {
    # Removes the bar of a tracker.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Progress)
    $Progress.Stopwatch.Stop()
    if ($script:EdgeQuiet) { return }
    $params = @{ Id = $Progress.Id; Activity = $Progress.Activity; Completed = $true }
    if ($Progress.ParentId -ge 0) { $params.ParentId = $Progress.ParentId }
    Write-Progress @params
}

function Write-EdgeStatus {
    <#
    .SYNOPSIS
        Writes a timestamped status line to the console (and the log with -Log). Silent when
        $script:EdgeQuiet is set. Levels: Info (default), Step (dim), Success (green), Warning (yellow),
        Header (cyan, no timestamp).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Step', 'Success', 'Warning', 'Header')][string]$Level = 'Info',
        [switch]$Log
    )
    if ($Log) {
        Write-EdgeSyncLog -Message $Message -Level ($Level -eq 'Warning' ? 'Warning' : 'Info') -WarningAction SilentlyContinue
    }
    if ($script:EdgeQuiet) { return }
    $color = switch ($Level) {
        'Step' { 'DarkGray' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Header' { 'Cyan' }
        default { 'Gray' }
    }
    $prefix = ($Level -eq 'Header' -or -not $Message) ? '' : "[$((Get-Date).ToString('HH:mm:ss'))] "
    Write-Host "$prefix$Message" -ForegroundColor $color
}

function Get-EdgePathSize {
    # Internal: total bytes of a file or directory tree; 0 when missing. Never throws.
    param([string]$Path)
    try {
        if ([System.IO.File]::Exists($Path)) { return ([System.IO.FileInfo]::new($Path)).Length }
        if ([System.IO.Directory]::Exists($Path)) {
            $sum = [long]0
            $opts = [System.IO.EnumerationOptions]::new()
            $opts.RecurseSubdirectories = $true
            $opts.IgnoreInaccessible = $true
            $opts.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
            foreach ($f in [System.IO.DirectoryInfo]::new($Path).EnumerateFiles('*', $opts)) { $sum += $f.Length }
            return $sum
        }
    }
    catch { Write-Verbose "Size of '$Path' failed: $($_.Exception.Message)" }
    [long]0
}
