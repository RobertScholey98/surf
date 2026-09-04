BeforeAll {
    Import-Module "$PSScriptRoot\..\Surf\Surf.psd1" -Force
}

Describe 'Expand-SurfTemplate' {
    It 'expands {dir} to the quoted viewed directory' {
        InModuleScope Surf {
            $r = Expand-SurfTemplate -Command 'ls {dir}' -Dir 'C:\my folder'
            $r.Ok | Should -BeTrue
            $r.Text | Should -Be 'ls "C:\my folder"'
        }
    }

    It 'expands {hovered} to the quoted item under the cursor' {
        InModuleScope Surf {
            $r = Expand-SurfTemplate -Command 'notepad {hovered}' -Hovered 'C:\proj\read me.txt' -Dir 'C:\proj'
            $r.Ok | Should -BeTrue
            $r.Text | Should -Be 'notepad "C:\proj\read me.txt"'
        }
    }

    It 'expands {selected} to all marked paths, quoted and space-separated' {
        InModuleScope Surf {
            $r = Expand-SurfTemplate -Command 'Copy-Item {selected} -Destination {dir}' `
                -Selected @('C:\a\one.txt', 'C:\b\two two.txt') -Dir 'C:\target'
            $r.Ok | Should -BeTrue
            $r.Text | Should -Be 'Copy-Item "C:\a\one.txt","C:\b\two two.txt" -Destination "C:\target"'
        }
    }

    It 'refuses to expand {selected} when nothing is marked' {
        InModuleScope Surf {
            $r = Expand-SurfTemplate -Command 'Copy-Item {selected} .' -Selected @() -Dir 'C:\x'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'marked'
        }
    }

    It 'passes commands with no placeholders through untouched' {
        InModuleScope Surf {
            $r = Expand-SurfTemplate -Command 'git status' -Dir 'C:\x' -Hovered 'C:\x\y.txt'
            $r.Ok | Should -BeTrue
            $r.Text | Should -Be 'git status'
        }
    }

    It 'leaves unrecognised braces alone so PowerShell scriptblocks survive' {
        InModuleScope Surf {
            $r = Expand-SurfTemplate -Command 'gci {dir} | % { $_.Name }' -Dir 'C:\x'
            $r.Ok | Should -BeTrue
            $r.Text | Should -Be 'gci "C:\x" | % { $_.Name }'
        }
    }
}

Describe 'Surf command store' {
    It 'round-trips an added command through the store file' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'commands.json'
            $r = Add-SurfCommand -Path $store -Key 'j' -Command 'yarn dev' -Description 'dev server' -Mode 'exit'
            $r.Ok | Should -BeTrue
            $all = @(Get-SurfCommandTable -Path $store)
            $all.Count | Should -Be 1
            $all[0].Key | Should -Be 'j'
            $all[0].Command | Should -Be 'yarn dev'
            $all[0].Description | Should -Be 'dev server'
            $all[0].Mode | Should -Be 'exit'
        }
    }

    It 'refuses a key that already has a command' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'commands.json'
            $null = Add-SurfCommand -Path $store -Key 'j' -Command 'yarn dev' -Description '' -Mode 'exit'
            $r = Add-SurfCommand -Path $store -Key 'j' -Command 'jest' -Description '' -Mode 'contained'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match "'j'"
            @(Get-SurfCommandTable -Path $store).Count | Should -Be 1
        }
    }

    It 'refuses a key that is a prefix of an existing chain, naming the conflicts' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'commands.json'
            $null = Add-SurfCommand -Path $store -Key 'gs' -Command 'git status' -Description '' -Mode 'contained'
            $null = Add-SurfCommand -Path $store -Key 'gp' -Command 'git push' -Description '' -Mode 'contained'
            $r = Add-SurfCommand -Path $store -Key 'g' -Command 'grep' -Description '' -Mode 'exit'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'gs'
            $r.Error | Should -Match 'gp'
        }
    }

    It 'refuses a chain that extends an existing command key' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'commands.json'
            $null = Add-SurfCommand -Path $store -Key 'gs' -Command 'git status' -Description '' -Mode 'contained'
            $r = Add-SurfCommand -Path $store -Key 'gsx' -Command 'git stash' -Description '' -Mode 'contained'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'gs'
        }
    }

    It 'refuses keys starting with a built-in command letter' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'commands.json'
            foreach ($key in @('b', 'f', 's', 't', 'q', 'bx')) {
                $r = Add-SurfCommand -Path $store -Key $key -Command 'anything' -Description '' -Mode 'exit'
                $r.Ok | Should -BeFalse -Because "'$key' starts with a built-in key"
                $r.Error | Should -Match 'built-in'
            }
        }
    }

    It 'refuses keys containing anything but letters and digits' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'commands.json'
            foreach ($key in @('/', '?', 'g s', '')) {
                $r = Add-SurfCommand -Path $store -Key $key -Command 'anything' -Description '' -Mode 'exit'
                $r.Ok | Should -BeFalse -Because "'$key' is not plain letters/digits"
            }
        }
    }

    It 'removes a command by key' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'remove-test.json'
            $null = Add-SurfCommand -Path $store -Key 'j' -Command 'yarn dev' -Description '' -Mode 'exit'
            $null = Add-SurfCommand -Path $store -Key 'x' -Command 'kubectl get pods' -Description '' -Mode 'contained'
            $r = Remove-SurfCommand -Path $store -Key 'j'
            $r.Ok | Should -BeTrue
            $remaining = @(Get-SurfCommandTable -Path $store)
            $remaining.Count | Should -Be 1
            $remaining[0].Key | Should -Be 'x'
        }
    }

    It 'reports an unknown key on remove' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'remove-test.json'
            $r = Remove-SurfCommand -Path $store -Key 'zz'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'zz'
        }
    }
}

Describe 'Surf updater' {
    It 'does nothing when the CurrentUser installation is already current' {
        InModuleScope Surf {
            Mock Get-Command { [pscustomobject]@{ Name = 'Update-PSResource' } }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Surf'; Version = [version]'0.5.3' } }
            Mock Get-InstalledPSResource { [pscustomobject]@{ Name = 'Surf'; Version = [version]'0.5.3' } }
            Mock Install-PSResource
            Mock Update-PSResource

            $result = Update-SurfInstallation

            $result.Status | Should -Be 'Current'
            $result.PreviousVersion | Should -Be ([version]'0.5.3')
            $result.Version | Should -Be ([version]'0.5.3')
            Should -Invoke Install-PSResource -Times 0
            Should -Invoke Update-PSResource -Times 0
        }
    }

    It 'updates an older CurrentUser installation to the Gallery version' {
        InModuleScope Surf {
            $script:installedCalls = 0
            Mock Get-Command { [pscustomobject]@{ Name = 'Update-PSResource' } }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Surf'; Version = [version]'0.5.3' } }
            Mock Get-InstalledPSResource {
                $script:installedCalls++
                $version = if ($script:installedCalls -eq 1) { '0.5.2' } else { '0.5.3' }
                [pscustomobject]@{ Name = 'Surf'; Version = [version]$version }
            }
            Mock Install-PSResource
            Mock Update-PSResource

            $result = Update-SurfInstallation

            $result.Status | Should -Be 'Updated'
            $result.PreviousVersion | Should -Be ([version]'0.5.2')
            $result.Version | Should -Be ([version]'0.5.3')
            Should -Invoke Update-PSResource -Times 1 -ParameterFilter {
                $Name -eq 'Surf' -and $Version -eq [version]'0.5.3' -and $Scope -eq 'CurrentUser'
            }
            Should -Invoke Install-PSResource -Times 0
        }
    }

    It 'installs the Gallery release when no CurrentUser copy exists' {
        InModuleScope Surf {
            $script:installedCalls = 0
            Mock Get-Command { [pscustomobject]@{ Name = 'Update-PSResource' } }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Surf'; Version = [version]'0.5.3' } }
            Mock Get-InstalledPSResource {
                $script:installedCalls++
                if ($script:installedCalls -gt 1) {
                    [pscustomobject]@{ Name = 'Surf'; Version = [version]'0.5.3' }
                }
            }
            Mock Install-PSResource
            Mock Update-PSResource

            $result = Update-SurfInstallation

            $result.Status | Should -Be 'Installed'
            $result.PreviousVersion | Should -BeNullOrEmpty
            $result.Version | Should -Be ([version]'0.5.3')
            Should -Invoke Install-PSResource -Times 1 -ParameterFilter {
                $Name -eq 'Surf' -and $Version -eq [version]'0.5.3' -and $Scope -eq 'CurrentUser'
            }
            Should -Invoke Update-PSResource -Times 0
        }
    }

    It 'honours WhatIf without changing the installation' {
        InModuleScope Surf {
            Mock Get-Command { [pscustomobject]@{ Name = 'Update-PSResource' } }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Surf'; Version = [version]'0.5.3' } }
            Mock Get-InstalledPSResource { [pscustomobject]@{ Name = 'Surf'; Version = [version]'0.5.2' } }
            Mock Install-PSResource
            Mock Update-PSResource

            $result = Update-SurfInstallation -WhatIf

            $result.Status | Should -Be 'Cancelled'
            Should -Invoke Install-PSResource -Times 0
            Should -Invoke Update-PSResource -Times 0
        }
    }

    It 'explains how to install PSResourceGet when it is unavailable' {
        InModuleScope Surf {
            Mock Get-Command { $null }

            { Update-SurfInstallation } | Should -Throw '*Microsoft.PowerShell.PSResourceGet*'
        }
    }

    It 'routes surf update through the updater without opening the navigator' {
        InModuleScope Surf {
            Mock Update-SurfInstallation {
                [pscustomobject]@{
                    Status          = 'Updated'
                    PreviousVersion = [version]'0.5.2'
                    Version         = [version]'0.5.3'
                }
            }

            surf update 6>$null

            Should -Invoke Update-SurfInstallation -Times 1
        }
    }
}

Describe 'Surf version command' {
    It 'reports the loaded module version with -v' {
        InModuleScope Surf {
            surf -v | Should -Be "Surf $((Get-Module Surf).Version)"
        }
    }

    It 'reports the loaded module version with -Version' {
        InModuleScope Surf {
            surf -Version | Should -Be "Surf $((Get-Module Surf).Version)"
        }
    }

    It 'also accepts the version subcommand' {
        InModuleScope Surf {
            surf version | Should -Be "Surf $((Get-Module Surf).Version)"
        }
    }
}

Describe 'Resolve-SurfKey' {
    It 'returns a run verdict with the command for a bound key' {
        InModuleScope Surf {
            $commands = @([pscustomobject]@{ Key = 'j'; Command = 'yarn dev'; Description = 'dev'; Mode = 'exit' })
            $v = Resolve-SurfKey -KeyChar 'j' -Commands $commands
            $v.Action | Should -Be 'run'
            $v.Command.Command | Should -Be 'yarn dev'
        }
    }

    It 'passes an unbound key through to the built-ins' {
        InModuleScope Surf {
            $commands = @([pscustomobject]@{ Key = 'j'; Command = 'yarn dev'; Description = 'dev'; Mode = 'exit' })
            $v = Resolve-SurfKey -KeyChar 'x' -Commands $commands
            $v.Action | Should -Be 'passthrough'
        }
    }

    It 'matches keys case-insensitively' {
        InModuleScope Surf {
            $commands = @([pscustomobject]@{ Key = 'j'; Command = 'yarn dev'; Description = 'dev'; Mode = 'exit' })
            $v = Resolve-SurfKey -KeyChar 'J' -Commands $commands
            $v.Action | Should -Be 'run'
        }
    }

    Context 'chains' {
        BeforeAll {
            $chainCommands = @(
                [pscustomobject]@{ Key = 'gs'; Command = 'git status'; Description = ''; Mode = 'contained' }
                [pscustomobject]@{ Key = 'gp'; Command = 'git push'; Description = ''; Mode = 'contained' }
                [pscustomobject]@{ Key = 'gcp'; Command = 'git cherry-pick'; Description = ''; Mode = 'contained' }
            )
        }

        It 'opens a menu of completions when a prefix key is pressed' {
            InModuleScope Surf -Parameters @{ commands = $chainCommands } {
                $v = Resolve-SurfKey -KeyChar 'g' -Commands $commands
                $v.Action | Should -Be 'menu'
                $v.Pending | Should -Be 'g'
                @($v.Completions).Count | Should -Be 3
            }
        }

        It 'runs the command when a pending chain is completed' {
            InModuleScope Surf -Parameters @{ commands = $chainCommands } {
                $v = Resolve-SurfKey -KeyChar 's' -Pending 'g' -Commands $commands
                $v.Action | Should -Be 'run'
                $v.Command.Command | Should -Be 'git status'
            }
        }

        It 'narrows to a deeper menu when the chain continues past another prefix' {
            InModuleScope Surf -Parameters @{ commands = $chainCommands } {
                $v = Resolve-SurfKey -KeyChar 'c' -Pending 'g' -Commands $commands
                $v.Action | Should -Be 'menu'
                $v.Pending | Should -Be 'gc'
                @($v.Completions).Count | Should -Be 1
            }
        }

        It 'resets when a pending chain gets an invalid continuation' {
            InModuleScope Surf -Parameters @{ commands = $chainCommands } {
                $v = Resolve-SurfKey -KeyChar 'x' -Pending 'g' -Commands $commands
                $v.Action | Should -Be 'reset'
            }
        }
    }
}

Describe 'SurfJob process helper' {
    # commands are PowerShell source: the launcher wraps them in powershell -EncodedCommand

    It 'captures stdout lines from a real child process' {
        $job = New-Object Surf.SurfJob('Write-Output one; Write-Output two', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while (-not $job.HasDrained -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $job.HasExited | Should -BeTrue
            $lines = @($job.SnapshotLines(0))
            $lines -contains 'one' | Should -BeTrue
            $lines -contains 'two' | Should -BeTrue
        } finally { $job.Dispose() }
    }

    It 'reports the child exit code' {
        $job = New-Object Surf.SurfJob('exit 3', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while (-not $job.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $job.ExitCode | Should -Be 3
        } finally { $job.Dispose() }
    }

    It 'runs the child in the requested working directory' {
        $job = New-Object Surf.SurfJob('(Get-Location).Path', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while (-not $job.HasDrained -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            @($job.SnapshotLines(0)) -contains $TestDrive.ToString() | Should -BeTrue
        } finally { $job.Dispose() }
    }

    It 'evicts oldest lines at the cap but keeps absolute indices monotonic' {
        $job = New-Object Surf.SurfJob('1..6000 | ForEach-Object { "line$_" }', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(60)
            while (-not $job.HasDrained -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            $job.HasDrained | Should -BeTrue
            $job.TotalLines | Should -BeGreaterOrEqual 6000
            $job.FirstIndex | Should -BeGreaterThan 0
            $lines = @($job.SnapshotLines(0))   # clamped to FirstIndex, no exception
            $lines.Count | Should -BeLessOrEqual 5000
            $lines[-1] | Should -Be 'line6000'
            # a snapshot from a mid-stream absolute index returns exactly the tail
            @($job.SnapshotLines($job.TotalLines - 3)).Count | Should -Be 3
        } finally { $job.Dispose() }
    }

    It 'exposes an unterminated prompt as a live partial line' {
        $job = New-Object Surf.SurfJob('[Console]::Out.Write("continue-y/n? "); $null = [Console]::In.ReadLine(); Write-Output done', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while ($job.PartialLine -notmatch 'y/n' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $job.PartialLine | Should -Match 'continue-y/n\?'
            $job.HasExited | Should -BeFalse
            $job.WriteInputLine('y') | Should -BeTrue
            $deadline = (Get-Date).AddSeconds(20)
            while (-not $job.HasDrained -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            # the answer completes the prompt's unterminated line, terminal-style
            @($job.SnapshotLines(0))[-1] | Should -Match 'done$'
        } finally { $job.Dispose() }
    }

    It 'refuses stdin writes after the child has gone' {
        $job = New-Object Surf.SurfJob('exit 0', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while (-not $job.HasDrained -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Start-Sleep -Milliseconds 200
            $job.WriteInputLine('into the void') | Should -BeFalse
        } finally { $job.Dispose() }
    }

    It 'keeps oversized CLIXML error blobs out of the visible output' {
        $job = New-Object Surf.SurfJob('Write-Error ([string]([char]120) * 6000)', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while (-not $job.HasDrained -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $lines = @($job.SnapshotLines(0))
            @($lines | Where-Object { $_ -match '^<Objs|^#< CLIXML' }).Count | Should -Be 0
        } finally { $job.Dispose() }
    }

    It 'surfaces verbose stream text from CLIXML instead of raw XML' {
        $job = New-Object Surf.SurfJob('Write-Verbose -Verbose "surf-verbose-probe"', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while (-not $job.HasDrained -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $lines = @($job.SnapshotLines(0))
            @($lines | Where-Object { $_ -match 'surf-verbose-probe' }).Count | Should -BeGreaterThan 0
            @($lines | Where-Object { $_ -match '^<Objs' }).Count | Should -Be 0
        } finally { $job.Dispose() }
    }

    It 'kills the whole process tree atomically' {
        $job = New-Object Surf.SurfJob('ping -n 60 127.0.0.1', $TestDrive)
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while (@(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($job.ProcessId)").Count -eq 0 -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            $job.HasExited | Should -BeFalse
            $childPids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($job.ProcessId)" |
                Select-Object -ExpandProperty ProcessId)
            $childPids.Count | Should -BeGreaterThan 0
            $job.KillTree()
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $job.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $job.HasExited | Should -BeTrue
            Start-Sleep -Milliseconds 500
            foreach ($childPid in $childPids) {
                (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
            }
            { $job.KillTree() } | Should -Not -Throw   # idempotent
        } finally { $job.Dispose() }
    }
}

Describe 'Remove-SurfAnsi' {
    It 'strips colour escape sequences' {
        InModuleScope Surf {
            $esc = [char]27
            Remove-SurfAnsi "$esc[32m$esc[1mPASS$esc[0m src/app.test.ts" | Should -Be 'PASS src/app.test.ts'
        }
    }

    It 'strips OSC title sequences and control characters' {
        InModuleScope Surf {
            $esc = [char]27; $bel = [char]7
            Remove-SurfAnsi "$esc]0;yarn$bel building$([char]13)" | Should -Be 'building'
        }
    }

    It 'leaves plain text untouched' {
        InModuleScope Surf {
            Remove-SurfAnsi 'compiled successfully in 1.2s' | Should -Be 'compiled successfully in 1.2s'
        }
    }

    It 'preserves text between two OSC sequences on one line' {
        InModuleScope Surf {
            $esc = [char]27; $bel = [char]7
            Remove-SurfAnsi "$esc]0;one$bel middle $esc]0;two$bel end" | Should -Be 'middle  end'
        }
    }
}

Describe 'Surf keymap' {
    It 'returns the default built-in bindings when no keymap file exists' {
        InModuleScope Surf {
            $km = Get-SurfKeymap -Path (Join-Path $TestDrive 'nope.json')
            $km.blacklist | Should -Be 'b'
            $km.favourite | Should -Be 'f'
            $km.search | Should -Be 's'
            $km.tab | Should -Be 't'
            $km.quit | Should -Be 'q'
            $km.kill | Should -Be 'k'
        }
    }

    It 'round-trips a rebound built-in' {
        InModuleScope Surf {
            $file = Join-Path $TestDrive 'keymap.json'
            $r = Set-SurfKeymapBinding -Path $file -Action 'blacklist' -Key 'x'
            $r.Ok | Should -BeTrue
            $km = Get-SurfKeymap -Path $file
            $km.blacklist | Should -Be 'x'
            $km.favourite | Should -Be 'f'
        }
    }

    It 'relocates a new default action when an older keymap already claimed its key' {
        InModuleScope Surf {
            # a pre-0.3.0 keymap could legally rebind a built-in to k before kill existed
            $file = Join-Path $TestDrive 'legacy-keymap.json'
            Set-Content -LiteralPath $file -Value '{"search":"k"}' -Encoding UTF8
            $km = Get-SurfKeymap -Path $file
            $km.search | Should -Be 'k'          # explicit binding wins
            $km.kill | Should -Not -Be 'k'       # displaced default moved...
            $km.kill | Should -Match '^[a-z0-9]$'
            $vals = @($km.Values)
            ($vals | Select-Object -Unique).Count | Should -Be $vals.Count   # ...and no key is double-bound
        }
    }

    It 'refuses a key already held by another built-in' {
        InModuleScope Surf {
            $file = Join-Path $TestDrive 'keymap2.json'
            $r = Set-SurfKeymapBinding -Path $file -Action 'blacklist' -Key 'f'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'favourite'
        }
    }

    It 'refuses a key that starts an existing custom command' {
        InModuleScope Surf {
            $file = Join-Path $TestDrive 'keymap3.json'
            $commands = @([pscustomobject]@{ Key = 'gs'; Command = 'git status'; Description = ''; Mode = 'contained' })
            $r = Set-SurfKeymapBinding -Path $file -Action 'blacklist' -Key 'g' -Commands $commands
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'gs'
        }
    }

    It 'accepts all four run modes' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'modes.json'
            $keys = @{ exit = 'e1'; contained = 'c1'; background = 'd1'; pane = 'p1' }
            foreach ($m in $keys.Keys) {
                $r = Add-SurfCommand -Path $store -Key $keys[$m] -Command 'x' -Description '' -Mode $m
                $r.Ok | Should -BeTrue -Because "mode '$m' is valid"
            }
        }
    }

    It 'refuses an unknown run mode' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'modes.json'
            $r = Add-SurfCommand -Path $store -Key 'zz' -Command 'x' -Description '' -Mode 'sideways'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'mode'
        }
    }

    It 'lets Add-SurfCommand use a rebound keymap: old letter freed, new letter reserved' {
        InModuleScope Surf {
            $store = Join-Path $TestDrive 'rebound-commands.json'
            $km = @{ blacklist = 'x'; favourite = 'f'; search = 's'; tab = 't'; quit = 'q' }
            $freed = Add-SurfCommand -Path $store -Key 'bb' -Command 'anything' -Description '' -Mode 'exit' -Keymap $km
            $freed.Ok | Should -BeTrue
            $taken = Add-SurfCommand -Path $store -Key 'x' -Command 'anything' -Description '' -Mode 'exit' -Keymap $km
            $taken.Ok | Should -BeFalse
            $taken.Error | Should -Match 'built-in'
        }
    }
}

Describe 'PS 5.1 List enumeration safety' {
    # Regression: Windows PowerShell 5.1 throws "Argument types do not match" when the
    # array-subexpression operator @() wraps a [System.Collections.Generic.List[object]]
    # variable (even an empty one). The 0.3.0 process table is such a list, so
    # `foreach ($pe in @($procTable))` crashed `surf` on launch for any directory.
    # PS 7 tolerates it, which is why CI's 7 leg and the headless smoke test missed it.
    # Snapshot generic lists with .ToArray() instead.
    It 'reproduces the 5.1 @()-on-List quirk this guards against (documents intent)' {
        $list = New-Object 'System.Collections.Generic.List[object]'
        if ($PSVersionTable.PSVersion.Major -le 5) {
            { @($list) } | Should -Throw   # ArgumentException: Argument types do not match
        }
        # .ToArray() is safe on every edition
        { @($list.ToArray()) } | Should -Not -Throw
    }

    It 'the module never wraps a generic List variable in bare @()' {
        $src = Get-Content "$PSScriptRoot\..\Surf\Surf.psm1" -Raw
        # $procTable is the only List[object] variable that gets enumerated; the safe
        # forms are `foreach ($x in $procTable)`, `$procTable.ToArray()`, or piping it
        # (`$procTable | Where-Object`). A bare @($procTable) must never reappear.
        $src | Should -Not -Match '@\(\$procTable\)'
    }
}
