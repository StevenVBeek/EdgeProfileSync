#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SAFETY: Register-ScheduledTask, Unregister-ScheduledTask and Get-ScheduledTask are always mocked.
# These tests never create, change or remove a real scheduled task. The New-ScheduledTask* cmdlets
# only build in-memory objects and are used for real, so the task definition itself is verified.

BeforeAll {
    $script:OriginalHome = $env:EDGEPROFILESYNC_HOME
    $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive 'localdata'

    $script:ManifestPath = (Resolve-Path (Join-Path $PSScriptRoot '..\EdgeProfileSync\EdgeProfileSync.psd1')).Path
    Import-Module $script:ManifestPath -Force -ErrorAction Stop
    $script:ExpectedTaskName = "EdgeProfileSync - $($env:USERNAME -replace '[\\/:*?"<>|]', '_')"
}

AfterAll {
    $env:EDGEPROFILESYNC_HOME = $script:OriginalHome
    Remove-Module EdgeProfileSync -Force -ErrorAction SilentlyContinue
}

Describe 'Register-EdgeProfileSyncTask' {
    BeforeEach {
        $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName EdgeProfileSync Get-ScheduledTask { }
        Mock -ModuleName EdgeProfileSync Unregister-ScheduledTask { }
        Mock -ModuleName EdgeProfileSync Register-ScheduledTask {
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = $TaskPath; InputObject = $InputObject }
        }
    }

    It 'registers the task in the EdgeProfileSync folder under the per-user name' {
        $result = Register-EdgeProfileSyncTask
        $result.TaskPath | Should -Be '\EdgeProfileSync\'
        $result.TaskName | Should -Be $script:ExpectedTaskName
        Should -Invoke -ModuleName EdgeProfileSync Register-ScheduledTask -Times 1 -Exactly
    }

    It 'runs pwsh headless through conhost and imports the module manifest' {
        $task = (Register-EdgeProfileSyncTask).InputObject
        $action = @($task.Actions)
        $action.Count | Should -Be 1
        $action[0].Execute | Should -Be (Join-Path $env:SystemRoot 'System32\conhost.exe')
        $action[0].Arguments | Should -BeLike '--headless "*pwsh.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "*'
        $action[0].Arguments | Should -BeLike "*Import-Module '$script:ManifestPath'; Sync-EdgeProfiles -Quiet`""
    }

    It 'escapes single quotes in the module path' {
        $dir = Join-Path $TestDrive "it's here"
        $null = New-Item -ItemType Directory -Path $dir -Force
        $psd1 = Join-Path $dir 'EdgeProfileSync.psd1'
        Copy-Item -LiteralPath $script:ManifestPath -Destination $psd1
        $task = (Register-EdgeProfileSyncTask -ModulePath $psd1).InputObject
        @($task.Actions)[0].Arguments | Should -BeLike "*Import-Module '$($psd1.Replace("'", "''"))'*"
    }

    It 'has a delayed logon trigger, a workstation lock trigger and a repeating trigger' {
        $task = (Register-EdgeProfileSyncTask -IntervalMinutes 20).InputObject
        $triggers = @($task.Triggers)
        $triggers.Count | Should -Be 3

        $logon = $triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }
        $logon | Should -Not -BeNullOrEmpty
        $logon.Delay | Should -Be 'PT1M'
        $logon.UserId | Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

        $lock = $triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskSessionStateChangeTrigger' }
        $lock | Should -Not -BeNullOrEmpty
        $lock.StateChange | Should -Be 7

        $repeat = $triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' }
        $repeat | Should -Not -BeNullOrEmpty
        $repeat.Repetition.Interval | Should -Be 'PT20M'
        $repeat.Repetition.Duration | Should -BeNullOrEmpty
    }

    It 'runs as the current user, interactive only, without elevation' {
        $principal = (Register-EdgeProfileSyncTask).InputObject.Principal
        $principal.UserId | Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $principal.LogonType | Should -Be 'Interactive'
        $principal.RunLevel | Should -Be 'Limited'
    }

    It 'uses the required task settings' {
        $settings = (Register-EdgeProfileSyncTask).InputObject.Settings
        $settings.DisallowStartIfOnBatteries | Should -BeFalse
        $settings.StopIfGoingOnBatteries | Should -BeFalse
        $settings.StartWhenAvailable | Should -BeTrue
        $settings.MultipleInstances | Should -Be 'IgnoreNew'
        $settings.ExecutionTimeLimit | Should -Be 'PT30M'
    }

    It 'uses IntervalMinutes from the configuration by default' {
        Set-EdgeProfileSyncConfig -IntervalMinutes 45
        $task = (Register-EdgeProfileSyncTask).InputObject
        (@($task.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' }).Repetition.Interval | Should -Be 'PT45M'
    }

    It 'stores -IntervalMinutes and -SyncRoot in the configuration' {
        $root = Join-Path $TestDrive 'sync-root'
        $null = Register-EdgeProfileSyncTask -IntervalMinutes 15 -SyncRoot $root
        $config = Get-EdgeProfileSyncConfig
        $config.IntervalMinutes | Should -Be 15
        $config.SyncRoot | Should -Be $root
        Test-Path -LiteralPath $root -PathType Container | Should -BeTrue
    }

    It 'refuses to replace an existing task without -Force' {
        Mock -ModuleName EdgeProfileSync Get-ScheduledTask {
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\EdgeProfileSync\' }
        }
        { Register-EdgeProfileSyncTask } | Should -Throw '*already exists*-Force*'
        Should -Invoke -ModuleName EdgeProfileSync Register-ScheduledTask -Times 0 -Exactly
    }

    It 'replaces an existing task with -Force' {
        Mock -ModuleName EdgeProfileSync Get-ScheduledTask {
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\EdgeProfileSync\' }
        }
        $null = Register-EdgeProfileSyncTask -Force
        Should -Invoke -ModuleName EdgeProfileSync Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $Force }
        Should -Invoke -ModuleName EdgeProfileSync Unregister-ScheduledTask -Times 0 -Exactly
    }

    It 'removes a fallback copy in the root folder when replacing' {
        Mock -ModuleName EdgeProfileSync Get-ScheduledTask {
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\' }
        }
        $null = Register-EdgeProfileSyncTask -Force
        Should -Invoke -ModuleName EdgeProfileSync Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\' }
    }

    It 'falls back to the root folder when the task folder cannot be created' {
        Mock -ModuleName EdgeProfileSync Register-ScheduledTask -ParameterFilter { $TaskPath -eq '\EdgeProfileSync\' } {
            throw [System.UnauthorizedAccessException]::new('Access is denied.')
        }
        $result = Register-EdgeProfileSyncTask -WarningAction SilentlyContinue
        $result.TaskPath | Should -Be '\'
    }

    It 'does not register anything with -WhatIf' {
        Register-EdgeProfileSyncTask -IntervalMinutes 10 -WhatIf
        Should -Invoke -ModuleName EdgeProfileSync Register-ScheduledTask -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json') | Should -BeFalse
    }

    It 'fails for a missing module manifest' {
        { Register-EdgeProfileSyncTask -ModulePath (Join-Path $TestDrive 'missing.psd1') } | Should -Throw '*not found*'
    }

    Context '-InstallModuleForUser' {
        It 'copies the module to the versioned user module folder and points the task there' {
            $modules = Join-Path $TestDrive 'Documents\PowerShell\Modules'
            $version = (Import-PowerShellDataFile $script:ManifestPath).ModuleVersion
            $task = (Register-EdgeProfileSyncTask -InstallModuleForUser -UserModuleRoot $modules).InputObject

            $installed = Join-Path $modules "EdgeProfileSync\$version\EdgeProfileSync.psd1"
            Test-Path -LiteralPath $installed | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $modules "EdgeProfileSync\$version\Public\Register-EdgeProfileSyncTask.ps1") | Should -BeTrue
            @($task.Actions)[0].Arguments | Should -BeLike "*Import-Module '$installed'*"
        }

        It 'replaces an earlier copy of the same version' {
            $modules = Join-Path $TestDrive 'Modules2'
            $version = (Import-PowerShellDataFile $script:ManifestPath).ModuleVersion
            $stale = Join-Path $modules "EdgeProfileSync\$version\stale.txt"
            $null = New-Item -ItemType File -Path $stale -Force
            $null = Register-EdgeProfileSyncTask -InstallModuleForUser -UserModuleRoot $modules
            Test-Path -LiteralPath $stale | Should -BeFalse
        }

        It 'copies nothing with -WhatIf' {
            $modules = Join-Path $TestDrive 'Modules3'
            Register-EdgeProfileSyncTask -InstallModuleForUser -UserModuleRoot $modules -WhatIf
            Test-Path -LiteralPath $modules | Should -BeFalse
        }
    }
}

Describe 'Unregister-EdgeProfileSyncTask' {
    BeforeEach {
        Mock -ModuleName EdgeProfileSync Unregister-ScheduledTask { }
        Mock -ModuleName EdgeProfileSync Register-ScheduledTask { throw 'must not be called' }
        Mock -ModuleName EdgeProfileSync Remove-EdgeSyncTaskFolderIfEmpty { }
    }

    It 'removes the task from the EdgeProfileSync folder and the root folder' {
        Mock -ModuleName EdgeProfileSync Get-ScheduledTask {
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\EdgeProfileSync\' }
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\' }
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\Other\' }
        }
        Unregister-EdgeProfileSyncTask -Confirm:$false
        Should -Invoke -ModuleName EdgeProfileSync Unregister-ScheduledTask -Times 2 -Exactly
        Should -Invoke -ModuleName EdgeProfileSync Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq $script:ExpectedTaskName -and $TaskPath -eq '\EdgeProfileSync\'
        }
        Should -Invoke -ModuleName EdgeProfileSync Unregister-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskPath -eq '\Other\' }
        Should -Invoke -ModuleName EdgeProfileSync Remove-EdgeSyncTaskFolderIfEmpty -Times 1 -Exactly
    }

    It 'warns when no task exists' {
        Mock -ModuleName EdgeProfileSync Get-ScheduledTask { }
        Unregister-EdgeProfileSyncTask -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName EdgeProfileSync Unregister-ScheduledTask -Times 0 -Exactly
    }

    It 'removes nothing with -WhatIf' {
        Mock -ModuleName EdgeProfileSync Get-ScheduledTask {
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\EdgeProfileSync\' }
        }
        Unregister-EdgeProfileSyncTask -WhatIf
        Should -Invoke -ModuleName EdgeProfileSync Unregister-ScheduledTask -Times 0 -Exactly
        Should -Invoke -ModuleName EdgeProfileSync Remove-EdgeSyncTaskFolderIfEmpty -Times 0 -Exactly
    }

    It 'accepts a custom task name' {
        Mock -ModuleName EdgeProfileSync Get-ScheduledTask {
            [pscustomobject]@{ TaskName = $TaskName; TaskPath = '\EdgeProfileSync\' }
        }
        Unregister-EdgeProfileSyncTask -TaskName 'EdgeProfileSync - other' -Confirm:$false
        Should -Invoke -ModuleName EdgeProfileSync Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'EdgeProfileSync - other' }
    }
}
