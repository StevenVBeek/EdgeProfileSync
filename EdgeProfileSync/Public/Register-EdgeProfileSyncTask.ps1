function Register-EdgeProfileSyncTask {
    <#
    .SYNOPSIS
        Registers a per-user scheduled task that runs Sync-EdgeProfiles in the background.

    .DESCRIPTION
        Creates the task "EdgeProfileSync - <user>" in the Task Scheduler folder "\EdgeProfileSync\".
        The task:
        - runs as the current user, only while that user is logged on (no stored password, no admin
          rights needed);
        - starts at logon of this user (after a 1 minute delay), when the workstation is locked, and
          every IntervalMinutes minutes;
        - runs "conhost.exe --headless pwsh.exe ... Sync-EdgeProfiles -Quiet", so no console window flashes;
        - also runs on battery, starts as soon as possible after a missed start, never runs twice at
          the same time and is stopped after 30 minutes.

        Use -InstallModuleForUser to copy the module into your PowerShell module folder first, so the
        task does not depend on the location you downloaded or cloned the module to.

        Run this once on every machine that should take part in the sync.

    .PARAMETER IntervalMinutes
        Repetition interval in minutes. Default: IntervalMinutes from the configuration (30).
        When passed, the value is also stored in the configuration.

    .PARAMETER ModulePath
        Full path of the EdgeProfileSync.psd1 the task imports. Default: the manifest of this module.

    .PARAMETER SyncRoot
        Optional: also sets the sync folder in the configuration (see Set-EdgeProfileSyncConfig).

    .PARAMETER InstallModuleForUser
        Copy the module to "<Documents>\PowerShell\Modules\EdgeProfileSync\<version>" and let the task
        import it from there.

    .PARAMETER UserModuleRoot
        Module folder used by -InstallModuleForUser. Default: "<Documents>\PowerShell\Modules".

    .PARAMETER Force
        Replace the task when it already exists.

    .EXAMPLE
        Register-EdgeProfileSyncTask -SyncRoot "$env:OneDrive\EdgeProfileSync" -InstallModuleForUser

        Sets the sync folder, installs the module for the current user and registers the sync task.

    .EXAMPLE
        Register-EdgeProfileSyncTask -IntervalMinutes 15 -Force

        Replaces the existing task with one that syncs every 15 minutes.

    .EXAMPLE
        Register-EdgeProfileSyncTask -WhatIf

        Shows what would be registered without changing anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(5, 1440)]
        [int]$IntervalMinutes,

        [ValidateNotNullOrEmpty()]
        [string]$ModulePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'EdgeProfileSync.psd1'),

        [ValidateNotNullOrEmpty()]
        [string]$SyncRoot,

        [switch]$InstallModuleForUser,

        [ValidateNotNullOrEmpty()]
        [string]$UserModuleRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'),

        [switch]$Force
    )

    $ModulePath = [System.IO.Path]::GetFullPath($ModulePath)
    if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
        throw "Module manifest '$ModulePath' not found."
    }

    # Configuration first, so the task's first run already uses it.
    $configParams = @{}
    if ($PSBoundParameters.ContainsKey('SyncRoot')) { $configParams['SyncRoot'] = $SyncRoot }
    if ($PSBoundParameters.ContainsKey('IntervalMinutes')) { $configParams['IntervalMinutes'] = $IntervalMinutes }
    if ($configParams.Count -gt 0) {
        Set-EdgeProfileSyncConfig @configParams
    }
    if (-not $PSBoundParameters.ContainsKey('IntervalMinutes')) {
        $IntervalMinutes = (Get-EdgeProfileSyncConfig).IntervalMinutes
    }

    $taskName = Get-EdgeSyncTaskName
    $existing = @(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskPath -in $script:EdgeSyncTaskPath, '\' })
    if ($existing.Count -gt 0 -and -not $Force) {
        throw "Scheduled task '$($existing[0].TaskPath)$taskName' already exists. Use -Force to replace it."
    }

    if ($InstallModuleForUser) {
        $ModulePath = Install-EdgeSyncModuleForUser -ModulePath $ModulePath -UserModuleRoot $UserModuleRoot
    }

    $userId = Get-EdgeSyncTaskUser
    $commandLine = Get-EdgeSyncTaskCommandLine -ModulePath $ModulePath

    $action = New-ScheduledTaskAction -Execute $commandLine.Execute -Argument $commandLine.Argument

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $logonTrigger.Delay = 'PT1M'
    $lockTrigger = New-EdgeSyncSessionLockTrigger -UserId $userId
    $intervalTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    $task = New-ScheduledTask -Action $action -Trigger @($logonTrigger, $lockTrigger, $intervalTrigger) `
        -Principal $principal -Settings $settings `
        -Description 'Syncs Microsoft Edge profiles (bookmarks, settings, history, collections) between machines via EdgeProfileSync.'

    $target = "$($script:EdgeSyncTaskPath)$taskName"
    if (-not $PSCmdlet.ShouldProcess($target, "Register scheduled task (every $IntervalMinutes min, at logon, on lock)")) {
        return
    }

    # Remove a copy in the root folder left by an earlier fallback registration.
    foreach ($old in $existing | Where-Object { $_.TaskPath -ne $script:EdgeSyncTaskPath }) {
        Unregister-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath -Confirm:$false
    }

    try {
        Register-ScheduledTask -TaskName $taskName -TaskPath $script:EdgeSyncTaskPath -InputObject $task -Force -ErrorAction Stop
    }
    catch [Microsoft.Management.Infrastructure.CimException], [System.UnauthorizedAccessException] {
        if ($_.Exception.Message -notmatch 'denied|0x80070005') { throw }
        # Some systems do not let standard users create Task Scheduler folders: use the root folder.
        Write-Warning "Cannot create task folder '$($script:EdgeSyncTaskPath)' ($($_.Exception.Message.Trim())). Registering '$taskName' in the root folder instead."
        Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $task -Force -ErrorAction Stop
    }
}
