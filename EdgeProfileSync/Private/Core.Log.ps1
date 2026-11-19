# Core helpers: logging to the PowerShell streams and to a daily log file.

$script:EdgeSyncLogPruned = $false
$script:EdgeSyncLogRetentionDays = 14

function Write-EdgeSyncLog {
    <#
    .SYNOPSIS
        Writes a message to the matching PowerShell stream and appends it to
        "<LocalDataPath>\logs\EdgeProfileSync-yyyyMMdd.log". Never throws on file errors.
    .DESCRIPTION
        Info and Verbose go to Write-Verbose, Warning to Write-Warning, Error to Write-Error as a
        non-terminating error (-ErrorAction Continue), so logging an error inside a catch block does not
        re-throw when the caller runs with $ErrorActionPreference = 'Stop'.
        Logs older than 14 days are pruned on the first write per session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error', 'Verbose')]
        [string]$Level = 'Info'
    )

    $now = Get-Date
    $line = '{0} {1} {2}' -f $now.ToString('yyyy-MM-ddTHH:mm:ss'), $Level.ToUpperInvariant(), $Message

    try {
        $logDir = Join-Path (Get-EdgeSyncLocalDataPath) 'logs'
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force
        }

        if (-not $script:EdgeSyncLogPruned) {
            $script:EdgeSyncLogPruned = $true
            $cutoff = $now.Date.AddDays(-$script:EdgeSyncLogRetentionDays)
            foreach ($old in @(Get-ChildItem -LiteralPath $logDir -Filter 'EdgeProfileSync-*.log' -File -ErrorAction SilentlyContinue)) {
                if ($old.BaseName -match '^EdgeProfileSync-(\d{8})$') {
                    $day = [datetime]::MinValue
                    if ([datetime]::TryParseExact($Matches[1], 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$day) -and $day -lt $cutoff) {
                        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        $logFile = Join-Path $logDir ('EdgeProfileSync-{0}.log' -f $now.ToString('yyyyMMdd'))
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line + [Environment]::NewLine)
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                # Shared append: the scheduled task and an interactive session may log at the same time.
                $fs = [IO.FileStream]::new($logFile, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
                break
            }
            catch [System.IO.IOException] {
                if ($attempt -ge 3) { throw }
                Start-Sleep -Milliseconds (100 * $attempt)
            }
        }
    }
    catch {
        Write-Verbose "EdgeProfileSync log write failed: $($_.Exception.Message)"
    }

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Error -Message $Message -ErrorAction Continue }
        default   { Write-Verbose $Message }
    }
}
