# Core helpers: Edge process detection and shutdown, per channel.
# Channels are told apart by the msedge.exe path ("...\Microsoft\Edge Beta\Application\msedge.exe").
# Only processes named exactly 'msedge' are considered; msedgewebview2 (Teams, Outlook) is never touched.

function Get-EdgeChannelProcess {
    <#
    .SYNOPSIS
        Internal: returns the msedge processes that belong to one channel. Processes whose path cannot
        be read are ignored (never attributed to a channel, never stopped).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel = 'Stable'
    )

    $folder = $script:EdgeChannelFolders[$Channel]
    $pattern = '\\Microsoft\\' + [regex]::Escape($folder) + '\\Application\\msedge\.exe$'

    foreach ($p in @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue)) {
        if ($null -eq $p) { continue }
        $name = $p.ProcessName
        if ($name -and $name -ne 'msedge') { continue }   # paranoia: never msedgewebview2
        $path = $p.Path
        if (-not $path) { continue }
        if ($path -match $pattern) { $p }
    }
}

function Get-EdgeProcessState {
    <#
    .SYNOPSIS
        Running / HasWindows / ProcessCount for the msedge processes of one channel.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel = 'Stable'
    )

    $procs = @(Get-EdgeChannelProcess -Channel $Channel)
    $windowed = @($procs | Where-Object { $_.MainWindowHandle -and [int64]$_.MainWindowHandle -ne 0 })

    [pscustomobject]@{
        Running      = $procs.Count -gt 0
        HasWindows   = $windowed.Count -gt 0
        ProcessCount = $procs.Count
    }
}

function Stop-EdgeProcess {
    <#
    .SYNOPSIS
        Stops Edge of one channel. Returns $true when no msedge process of that channel is left.
    .DESCRIPTION
        -BackgroundOnly: only acts when no process of that channel has a visible window (Startup Boost /
        background mode); returns $false otherwise without touching anything.
        Without -BackgroundOnly, windows are closed gracefully first (CloseMainWindow) and processes that
        remain after half the timeout are stopped with Stop-Process.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel = 'Stable',

        [switch]$BackgroundOnly,

        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds = 15
    )

    $state = Get-EdgeProcessState -Channel $Channel
    if (-not $state.Running) { return $true }

    if ($BackgroundOnly -and $state.HasWindows) {
        Write-Verbose "Edge $Channel has visible windows; not stopping (BackgroundOnly)."
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess("Microsoft Edge ($Channel), $($state.ProcessCount) process(es)", 'Stop')) {
        return $false
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    if ($state.HasWindows) {
        # Graceful: ask every window to close, then give Edge time to shut down on its own.
        foreach ($p in @(Get-EdgeChannelProcess -Channel $Channel)) {
            if ($p.MainWindowHandle -and [int64]$p.MainWindowHandle -ne 0) {
                try { $null = $p.CloseMainWindow() } catch { Write-Verbose "CloseMainWindow failed for $($p.Id): $($_.Exception.Message)" }
            }
        }
        $graceDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, [int]($TimeoutSeconds / 2)))
        while ([DateTime]::UtcNow -lt $graceDeadline) {
            if (-not (Get-EdgeProcessState -Channel $Channel).Running) { return $true }
            Start-Sleep -Milliseconds 250
        }
    }

    # Background processes (or windows that did not close): stop only this channel's msedge processes.
    $ids = @(Get-EdgeChannelProcess -Channel $Channel | ForEach-Object { $_.Id })
    if ($ids.Count -gt 0) {
        Stop-Process -Id $ids -ErrorAction SilentlyContinue
    }

    while ($true) {
        if (-not (Get-EdgeProcessState -Channel $Channel).Running) { return $true }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 250
    }
    Write-Verbose "Edge $Channel still running after $TimeoutSeconds seconds."
    $false
}
