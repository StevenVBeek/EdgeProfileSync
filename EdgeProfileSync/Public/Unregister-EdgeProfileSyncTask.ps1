function Unregister-EdgeProfileSyncTask {
    <#
    .SYNOPSIS
        Removes the scheduled sync task of the current user.

    .DESCRIPTION
        Removes the task "EdgeProfileSync - <user>" created by Register-EdgeProfileSyncTask from the
        Task Scheduler folder "\EdgeProfileSync\" (and from the root folder, where it is placed when
        the folder could not be created). The folder itself is removed when it is empty.

        The configuration, the local sync state, the sync folder and any installed module copy are
        left untouched.

    .PARAMETER TaskName
        Name of the task to remove. Default: "EdgeProfileSync - <current user>".

    .EXAMPLE
        Unregister-EdgeProfileSyncTask

        Stops the background sync on this machine.

    .EXAMPLE
        Unregister-EdgeProfileSyncTask -WhatIf

        Shows which task would be removed.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = (Get-EdgeSyncTaskName)
    )

    $tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskPath -in $script:EdgeSyncTaskPath, '\' })

    if ($tasks.Count -eq 0) {
        Write-Warning "Scheduled task '$TaskName' was not found."
        return
    }

    foreach ($task in $tasks) {
        if ($PSCmdlet.ShouldProcess("$($task.TaskPath)$($task.TaskName)", 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Verbose "Removed scheduled task '$($task.TaskPath)$($task.TaskName)'."
        }
    }

    if (-not $WhatIfPreference) {
        Remove-EdgeSyncTaskFolderIfEmpty -FolderPath $script:EdgeSyncTaskPath.TrimEnd('\')
    }
}
