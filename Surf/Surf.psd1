@{
    RootModule           = 'Surf.psm1'
    ModuleVersion        = '0.5.3'
    GUID                 = 'ffbb58b2-9820-4242-85ec-50fb26b0fc9f'
    Author               = 'Rob Scholey'
    Copyright            = '(c) 2026 Rob Scholey. All rights reserved.'
    Description          = 'An interactive directory navigator for the terminal. Browse with arrow keys, cd with Enter, plus favourites, a blacklist, recursive folder search, and Windows Terminal tab integration. Windows only.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('surf')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('TUI', 'navigation', 'filesystem', 'directory', 'interactive', 'Windows')
            LicenseUri   = 'https://github.com/RobertScholey98/surf/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/RobertScholey98/surf'
            ReleaseNotes = '0.5.3: adds surf update, which installs or updates the CurrentUser PowerShell Gallery release without modifying a development checkout. Documentation now covers Gallery installation, release-versus-development workflows, discoverable command chains, and Git/GitHub authentication. 0.5.2: restores current PowerShell 7 compatibility for the compiled background-process helper and improves cross-edition CI coverage. 0.5.1: worktree badges also show how many commits a worktree is behind the default branch (as last fetched). 0.5.0: worktree rows in the management area carry a right-hand status badge (N changed, N unpushed) showing uncommitted files and commits no remote has - blank when clean. 0.4.2: new local branches are created with --no-track, so git push no longer targets the base branch (origin/master) under the wrong name. 0.4.1: worktree operations show a live spinner with elapsed seconds while git works (removing a large worktree visibly makes progress instead of looking frozen), git runs with stdin closed and terminal prompts disabled so it errors instead of hanging, and failures surface git''s own fatal/error line in the footer. 0.4.0: git worktree management. W opens a worktree area inside any git repo: Enter browses into a worktree, N creates a new local branch+worktree (Enter at the base prompt means latest default branch, fetched), R checks out a remote branch or open PR (via gh when installed) into a new worktree, D removes a worktree AND its local branch behind confirms (extra confirm on uncommitted changes; main worktree never removable). Stale registrations auto-prune; linked worktrees show as a pinned group while browsing the repo.'
        }
    }
}
