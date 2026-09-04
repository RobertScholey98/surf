BeforeAll {
    Import-Module "$PSScriptRoot\..\Surf\Surf.psd1" -Force
}

Describe 'ConvertFrom-SurfWorktreeList' {
    It 'parses a porcelain listing into path, branch and main-worktree flags' {
        InModuleScope Surf {
            $porcelain = @(
                'worktree C:/repos/surf'
                'HEAD 0123456789abcdef0123456789abcdef01234567'
                'branch refs/heads/main'
                ''
                'worktree C:/repos/surf/.claude/worktrees/fix-login'
                'HEAD fedcba9876543210fedcba9876543210fedcba98'
                'branch refs/heads/fix-login'
                ''
            ) -join "`n"
            $wts = @(ConvertFrom-SurfWorktreeList -Text $porcelain -CurrentDir 'C:\repos\surf')
            $wts.Count | Should -Be 2
            $wts[0].Path | Should -Be 'C:\repos\surf'
            $wts[0].Branch | Should -Be 'main'
            $wts[0].IsMain | Should -BeTrue
            $wts[1].Path | Should -Be 'C:\repos\surf\.claude\worktrees\fix-login'
            $wts[1].Branch | Should -Be 'fix-login'
            $wts[1].IsMain | Should -BeFalse
        }
    }

    It 'flags the current worktree by longest path match, even when a worktree nests inside the main one' {
        InModuleScope Surf {
            $porcelain = @(
                'worktree C:/repos/surf'
                'HEAD 0123456789abcdef0123456789abcdef01234567'
                'branch refs/heads/main'
                ''
                'worktree C:/repos/surf/.claude/worktrees/fix-login'
                'HEAD fedcba9876543210fedcba9876543210fedcba98'
                'branch refs/heads/fix-login'
                ''
            ) -join "`n"
            # standing deep inside the nested worktree: it wins, not the main one containing it
            $inside = @(ConvertFrom-SurfWorktreeList -Text $porcelain -CurrentDir 'C:\repos\surf\.claude\worktrees\fix-login\src')
            $inside[0].IsCurrent | Should -BeFalse
            $inside[1].IsCurrent | Should -BeTrue
            # standing in the main worktree, outside the nested one
            $inMain = @(ConvertFrom-SurfWorktreeList -Text $porcelain -CurrentDir 'C:\repos\surf\docs')
            $inMain[0].IsCurrent | Should -BeTrue
            $inMain[1].IsCurrent | Should -BeFalse
            # a sibling path that merely shares the name prefix is not inside the worktree
            $outside = @(ConvertFrom-SurfWorktreeList -Text $porcelain -CurrentDir 'C:\repos\surf-other')
            @($outside | Where-Object { $_.IsCurrent }).Count | Should -Be 0
        }
    }

    It 'parses detached and bare entries with a null branch instead of choking' {
        InModuleScope Surf {
            $porcelain = @(
                'worktree C:/repos/store.git'
                'bare'
                ''
                'worktree C:/repos/store.git/wt/experiment'
                'HEAD fedcba9876543210fedcba9876543210fedcba98'
                'detached'
                ''
            ) -join "`n"
            $wts = @(ConvertFrom-SurfWorktreeList -Text $porcelain -CurrentDir 'C:\elsewhere')
            $wts.Count | Should -Be 2
            $wts[0].Branch | Should -BeNullOrEmpty
            $wts[1].Branch | Should -BeNullOrEmpty
            $wts[1].Path | Should -Be 'C:\repos\store.git\wt\experiment'
        }
    }

    It 'returns nothing for empty input' {
        InModuleScope Surf {
            @(ConvertFrom-SurfWorktreeList -Text '' -CurrentDir 'C:\x').Count | Should -Be 0
        }
    }

    It 'flags bare entries so a bare-layout repo can be anchored correctly' {
        InModuleScope Surf {
            $porcelain = @(
                'worktree C:/repos/myproj/.bare'
                'bare'
                ''
                'worktree C:/repos/myproj/main'
                'HEAD 0123456789abcdef0123456789abcdef01234567'
                'branch refs/heads/main'
                ''
            ) -join "`n"
            $wts = @(ConvertFrom-SurfWorktreeList -Text $porcelain -CurrentDir 'C:\repos\myproj')
            $wts[0].IsBare | Should -BeTrue
            $wts[1].IsBare | Should -BeFalse
        }
    }
}

Describe 'ConvertTo-SurfArgString' {
    It 'quotes only what needs quoting and survives trailing backslashes and embedded quotes' {
        InModuleScope Surf {
            ConvertTo-SurfArgString @('worktree', 'remove', 'C:\plain\path') | Should -Be 'worktree remove C:\plain\path'
            ConvertTo-SurfArgString @('-C', 'C:\has space\repo') | Should -Be '-C "C:\has space\repo"'
            # a trailing backslash inside quotes must not escape the closing quote
            ConvertTo-SurfArgString @('C:\has space\') | Should -Be '"C:\has space\\"'
            ConvertTo-SurfArgString @('say "hi"') | Should -Be '"say \"hi\""'
            ConvertTo-SurfArgString @('') | Should -Be '""'
        }
    }
}

Describe 'Format-SurfWorktreeBadge' {
    It 'names uncommitted files and unpushed commits, and stays silent when clean' {
        InModuleScope Surf {
            Format-SurfWorktreeBadge -Changed 0 -Unpushed 0 | Should -Be ''
            Format-SurfWorktreeBadge -Changed 3 -Unpushed 0 | Should -Be '3 changed'
            Format-SurfWorktreeBadge -Changed 0 -Unpushed 2 | Should -Be '2 unpushed'
            Format-SurfWorktreeBadge -Changed 3 -Unpushed 2 | Should -Be '3 changed, 2 unpushed'
        }
    }

    It 'names commits the worktree is behind the default branch' {
        InModuleScope Surf {
            Format-SurfWorktreeBadge -Changed 0 -Unpushed 0 -Behind 5 | Should -Be '5 behind'
            Format-SurfWorktreeBadge -Changed 3 -Unpushed 2 -Behind 5 | Should -Be '3 changed, 2 unpushed, 5 behind'
            Format-SurfWorktreeBadge -Changed 1 -Unpushed 0 -Behind 0 | Should -Be '1 changed'
        }
    }
}

Describe 'Resolve-SurfWorktreeRoot' {
    It 'anchors a normal repo at the main worktree, listing every entry as a row' {
        InModuleScope Surf {
            $wts = @(
                [pscustomobject]@{ Path = 'C:\repos\surf'; Branch = 'main'; IsMain = $true; IsBare = $false; IsCurrent = $true }
                [pscustomobject]@{ Path = 'C:\repos\surf\.claude\worktrees\fix'; Branch = 'fix'; IsMain = $false; IsBare = $false; IsCurrent = $false }
            )
            $root = Resolve-SurfWorktreeRoot -Worktrees $wts
            $root.MainRoot | Should -Be 'C:\repos\surf'
            @($root.Rows).Count | Should -Be 2
        }
    }

    It 'anchors a bare layout at the bare repo''s parent and hides the bare entry from the rows' {
        InModuleScope Surf {
            # the .bare convention: worktrees live alongside .bare at the project root
            $wts = @(
                [pscustomobject]@{ Path = 'C:\repos\myproj\.bare'; Branch = $null; IsMain = $true; IsBare = $true; IsCurrent = $false }
                [pscustomobject]@{ Path = 'C:\repos\myproj\main'; Branch = 'main'; IsMain = $false; IsBare = $false; IsCurrent = $true }
                [pscustomobject]@{ Path = 'C:\repos\myproj\feature'; Branch = 'feature'; IsMain = $false; IsBare = $false; IsCurrent = $false }
            )
            $root = Resolve-SurfWorktreeRoot -Worktrees $wts
            $root.MainRoot | Should -Be 'C:\repos\myproj'
            @($root.Rows).Count | Should -Be 2
            @($root.Rows | Where-Object { $_.IsBare }).Count | Should -Be 0
        }
    }
}

Describe 'ConvertFrom-SurfPrJson' {
    It 'turns gh pr list JSON into picker entries labelled "#number title [branch]"' {
        InModuleScope Surf {
            $json = '[{"number":42,"title":"Fix login flow","headRefName":"fix-login"},{"number":7,"title":"Add dark mode","headRefName":"feat/dark-mode"}]'
            $entries = @(ConvertFrom-SurfPrJson -Json $json)
            $entries.Count | Should -Be 2
            $entries[0].Display | Should -Be '#42 Fix login flow [fix-login]'
            $entries[0].Branch | Should -Be 'fix-login'
            $entries[1].Display | Should -Be '#7 Add dark mode [feat/dark-mode]'
            $entries[1].Branch | Should -Be 'feat/dark-mode'
        }
    }

    It 'returns nothing for empty or blank JSON' {
        InModuleScope Surf {
            @(ConvertFrom-SurfPrJson -Json '').Count | Should -Be 0
            @(ConvertFrom-SurfPrJson -Json '[]').Count | Should -Be 0
        }
    }
}

Describe 'ConvertFrom-SurfRemoteHeads' {
    It 'turns git ls-remote --heads output into branch entries sorted by name' {
        InModuleScope Surf {
            $tab = [char]9
            $text = @(
                "fedcba9876543210fedcba9876543210fedcba98${tab}refs/heads/zeta"
                "0123456789abcdef0123456789abcdef01234567${tab}refs/heads/alpha"
                "aaaa456789abcdef0123456789abcdef01234567${tab}refs/heads/feat/dark-mode"
            ) -join "`n"
            $entries = @(ConvertFrom-SurfRemoteHeads -Text $text)
            $entries.Count | Should -Be 3
            @($entries | ForEach-Object { $_.Branch }) | Should -Be @('alpha', 'feat/dark-mode', 'zeta')
            $entries[0].Display | Should -Be 'alpha'
        }
    }

    It 'returns nothing for empty input' {
        InModuleScope Surf {
            @(ConvertFrom-SurfRemoteHeads -Text '').Count | Should -Be 0
        }
    }
}

Describe 'Resolve-SurfWorktreeAddPlan' {
    It 'plans a local add: new branch from the base ref with no upstream, worktree at the repo-root-relative path' {
        InModuleScope Surf {
            $plan = Resolve-SurfWorktreeAddPlan -Kind 'local' -BranchName 'fix-login' -BaseRef 'origin/main' `
                -RepoRoot 'C:\repos\surf' -RelativePath 'fix-login' -ExistingBranches @('main', 'other')
            $plan.Ok | Should -BeTrue
            $plan.WorktreePath | Should -Be 'C:\repos\surf\fix-login'
            $plan.Steps.Count | Should -Be 1
            # --no-track matters: without it, branching from a remote-tracking ref
            # auto-sets upstream to the base (origin/main), and a later `git push`
            # refuses because the upstream name does not match the branch name
            @($plan.Steps[0]) | Should -Be @('worktree', 'add', '--no-track', '-b', 'fix-login', 'C:\repos\surf\fix-login', 'origin/main')
        }
    }

    It 'plans a remote add: fetch the branch, then check it out tracking the remote' {
        InModuleScope Surf {
            $plan = Resolve-SurfWorktreeAddPlan -Kind 'remote' -BranchName 'feat/dark-mode' `
                -RepoRoot 'C:\repos\surf' -RelativePath 'dark-mode' -ExistingBranches @('main')
            $plan.Ok | Should -BeTrue
            $plan.WorktreePath | Should -Be 'C:\repos\surf\dark-mode'
            $plan.Steps.Count | Should -Be 2
            @($plan.Steps[0]) | Should -Be @('fetch', 'origin', 'feat/dark-mode')
            @($plan.Steps[1]) | Should -Be @('worktree', 'add', '--track', '-b', 'feat/dark-mode', 'C:\repos\surf\dark-mode', 'origin/feat/dark-mode')
        }
    }

    It 'refuses a branch name that already exists locally, naming it' {
        InModuleScope Surf {
            foreach ($kind in @('local', 'remote')) {
                $plan = Resolve-SurfWorktreeAddPlan -Kind $kind -BranchName 'main' -BaseRef 'origin/main' `
                    -RepoRoot 'C:\repos\surf' -RelativePath 'x' -ExistingBranches @('main', 'fix-login')
                $plan.Ok | Should -BeFalse -Because "kind '$kind' must refuse an existing branch"
                $plan.Error | Should -Match "'main'"
            }
        }
    }

    It 'refuses empty and git-illegal branch names' {
        InModuleScope Surf {
            foreach ($bad in @('', '   ', 'has space', 'bad..name', '-leading-dash', 'ends.lock', 'has~tilde', 'has^caret', 'has:colon', 'has?mark', 'has*star', 'has[bracket', 'has\backslash', 'trailing/')) {
                $plan = Resolve-SurfWorktreeAddPlan -Kind 'local' -BranchName $bad -BaseRef 'origin/main' `
                    -RepoRoot 'C:\repos\surf' -RelativePath 'x' -ExistingBranches @()
                $plan.Ok | Should -BeFalse -Because "'$bad' is not a legal branch name"
            }
        }
    }

    It 'defaults a blank path to the branch name and resolves nested relative paths from the repo root' {
        InModuleScope Surf {
            $blank = Resolve-SurfWorktreeAddPlan -Kind 'local' -BranchName 'fix-login' -BaseRef 'main' `
                -RepoRoot 'C:\repos\surf' -RelativePath '' -ExistingBranches @()
            $blank.Ok | Should -BeTrue
            $blank.WorktreePath | Should -Be 'C:\repos\surf\fix-login'
            $nested = Resolve-SurfWorktreeAddPlan -Kind 'local' -BranchName 'fix-login' -BaseRef 'main' `
                -RepoRoot 'C:\repos\surf' -RelativePath 'wt\fix-login' -ExistingBranches @()
            $nested.WorktreePath | Should -Be 'C:\repos\surf\wt\fix-login'
            $outside = Resolve-SurfWorktreeAddPlan -Kind 'local' -BranchName 'fix-login' -BaseRef 'main' `
                -RepoRoot 'C:\repos\surf' -RelativePath '..\surf-wt\fix-login' -ExistingBranches @()
            $outside.WorktreePath | Should -Be 'C:\repos\surf-wt\fix-login'
        }
    }

    It 'sanitises slashes out of the default path for a branch named with slashes' {
        InModuleScope Surf {
            $plan = Resolve-SurfWorktreeAddPlan -Kind 'remote' -BranchName 'feat/dark-mode' `
                -RepoRoot 'C:\repos\surf' -RelativePath '' -ExistingBranches @()
            $plan.Ok | Should -BeTrue
            $plan.WorktreePath | Should -Be 'C:\repos\surf\feat-dark-mode'
        }
    }

    It 'refuses a target path already registered to another worktree, case-insensitively' {
        InModuleScope Surf {
            $plan = Resolve-SurfWorktreeAddPlan -Kind 'local' -BranchName 'new-work' -BaseRef 'main' `
                -RepoRoot 'C:\repos\surf' -RelativePath 'Fix-Login' -ExistingBranches @() `
                -ExistingWorktreePaths @('C:\repos\surf', 'C:\repos\surf\fix-login')
            $plan.Ok | Should -BeFalse
            $plan.Error | Should -Match 'worktree'
        }
    }
}

Describe 'Resolve-SurfWorktreeRemovePlan' {
    It 'plans a clean removal: remove the worktree, then force-delete its branch' {
        InModuleScope Surf {
            $wt = [pscustomobject]@{ Path = 'C:\repos\surf\fix-login'; Branch = 'fix-login'; IsMain = $false; IsCurrent = $false }
            $plan = Resolve-SurfWorktreeRemovePlan -Worktree $wt -IsDirty $false
            $plan.Ok | Should -BeTrue
            $plan.RequiresForce | Should -BeFalse
            $plan.Steps.Count | Should -Be 2
            @($plan.Steps[0]) | Should -Be @('worktree', 'remove', 'C:\repos\surf\fix-login')
            @($plan.Steps[1]) | Should -Be @('branch', '-D', 'fix-login')
        }
    }

    It 'refuses to remove the main worktree, even forced' {
        InModuleScope Surf {
            $wt = [pscustomobject]@{ Path = 'C:\repos\surf'; Branch = 'main'; IsMain = $true; IsCurrent = $true }
            $plan = Resolve-SurfWorktreeRemovePlan -Worktree $wt -IsDirty $false -Force
            $plan.Ok | Should -BeFalse
            $plan.Error | Should -Match 'main worktree'
            $plan.Steps | Should -BeNullOrEmpty
        }
    }

    It 'holds a dirty worktree behind an explicit force confirmation' {
        InModuleScope Surf {
            $wt = [pscustomobject]@{ Path = 'C:\repos\surf\fix-login'; Branch = 'fix-login'; IsMain = $false; IsCurrent = $false }
            $held = Resolve-SurfWorktreeRemovePlan -Worktree $wt -IsDirty $true
            $held.Ok | Should -BeTrue
            $held.RequiresForce | Should -BeTrue
            $held.Steps | Should -BeNullOrEmpty
            $forced = Resolve-SurfWorktreeRemovePlan -Worktree $wt -IsDirty $true -Force
            $forced.Ok | Should -BeTrue
            $forced.RequiresForce | Should -BeFalse
            @($forced.Steps[0]) | Should -Be @('worktree', 'remove', '--force', 'C:\repos\surf\fix-login')
            @($forced.Steps[1]) | Should -Be @('branch', '-D', 'fix-login')
        }
    }

    It 'skips branch deletion for a detached worktree' {
        InModuleScope Surf {
            $wt = [pscustomobject]@{ Path = 'C:\repos\surf\experiment'; Branch = $null; IsMain = $false; IsCurrent = $false }
            $plan = Resolve-SurfWorktreeRemovePlan -Worktree $wt -IsDirty $false
            $plan.Ok | Should -BeTrue
            $plan.Steps.Count | Should -Be 1
            @($plan.Steps[0]) | Should -Be @('worktree', 'remove', 'C:\repos\surf\experiment')
        }
    }
}
