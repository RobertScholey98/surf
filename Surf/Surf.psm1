# Surf - an interactive directory navigator for the terminal.
#
# Usage:
#   surf                              browse from the current directory
#   surf blacklist                    manage blacklisted folders and files
#   surf add <key> "<command>"        bind a key to a command (-Exit / -Contained skip the prompt)
#   surf remove <key>                 unbind a key
#   surf help                         list built-in keys and custom commands
#
# Multi-character keys are chains: 'surf add gs "git status"' means g then s, and
# pressing g inside surf shows a which-key menu of every g... completion. Adding a
# command on a built-in key offers to relocate the built-in (stored in keymap.json).
#
# Run modes: exit (leave surf, run in the terminal), contained (run inside surf,
# return to browsing), background (keep browsing; the process pins to the top of
# every listing - Enter attaches to a live tail with stdin forwarding, Ctrl+C stops
# the process tree, Esc Esc detaches, PgUp scrolls history, K kills/dismisses), and
# pane (opens in a Windows Terminal split - the home for full TUIs like claude).
# Background processes are scoped to the surf session: leaving surf stops them
# after a Y/N confirm, and a kernel job object guarantees nothing is orphaned.
#
# Custom commands support {hovered} (item under cursor), {selected} (Space-marked
# items) and {dir} (viewed folder); expansions are quoted automatically.
#
# Keys (browse):
#   Up/Down          move cursor
#   Right            enter highlighted folder (or drive)
#   Left             go up one level; at a drive root, show the drive picker
#   Enter            cd the terminal session to the highlighted folder
#                    (on the top ". (stay here)" entry, cd to the folder being viewed)
#   F                toggle favourite on the highlighted folder or file. Favourites are
#                    starred (*) and float to the top of every listing (folders, then files).
#   B                blacklist the highlighted folder or file (hides it from surf listings).
#                    Directories with blocked items show a virtual "surf-blocklist (n folders,
#                    n files)" entry at the bottom - Enter/Right opens it to un-list (B),
#                    cd (Enter) or browse (Right); Left/Esc returns to the listing.
#   T                open the highlighted folder in a new terminal tab (Windows Terminal;
#                    falls back to a new PowerShell window if wt.exe is not available)
#   S                search: type a query, Enter finds folders recursively under the
#                    current directory (first 200 matches), Esc cancels. In the results
#                    list, Left/Esc goes back to browsing; Enter/Right/B/T work as usual.
#   Del              delete the highlighted folder or file to the Recycle Bin,
#                    after a Y/N confirmation in the footer
#   Space            mark/un-mark the highlighted folder or file. Marks pin to a
#                    group at the top of every listing, survive navigation, and feed
#                    {selected}; Esc clears them all
#   W                worktree management area (inside a git repo): every worktree
#                    listed with its branch, the one you're in pre-selected. Enter
#                    browses into a worktree, N creates a new local branch+worktree
#                    (base ref prompt - Enter means latest default branch, fetched),
#                    R checks out a remote branch or open PR (via gh when installed)
#                    into a new worktree, D removes the selected worktree AND its
#                    local branch after a confirm (a second confirm if it has
#                    uncommitted changes; the main worktree is never removable).
#                    Esc/W back. In browse, linked worktrees show as a pinned
#                    "worktrees (n)" group - navigation only.
#   /                then a letter: jump to the next folder starting with it
#   a-z / 0-9        run the custom command bound to that key (see surf add); a chain
#                    prefix opens a which-key menu of its completions
#   ?                help overlay: every binding, built-in and custom
#   Esc / Q          quit without changing directory (Esc clears marks first)
#   Home/End/PgUp/PgDn  larger cursor jumps
#
# Keys (blacklist view):
#   B                un-list the highlighted item
#   Enter            cd to the highlighted folder
#   Right            browse into the highlighted folder
#
# State lives in %APPDATA%\surf\ (blacklist.txt and favourites.txt, one full path per line).

# Compile the native process helper once per session. Assemblies cannot unload on
# .NET Framework, so re-imports reuse the loaded type; changing SurfJob.cs therefore
# requires a fresh PowerShell session.
if (-not ('Surf.SurfJob' -as [type])) {
    $surfJobRefs = if ($PSVersionTable.PSEdition -eq 'Core') {
        @('System.Diagnostics.Process', 'System.Threading.Thread', 'System.ComponentModel.Primitives', 'netstandard')
    } else {
        @('System.dll')
    }
    Add-Type -Path (Join-Path $PSScriptRoot 'SurfJob.cs') -ReferencedAssemblies $surfJobRefs
}

$script:SurfDataDir        = Join-Path $env:APPDATA 'surf'
$script:SurfBlacklistFile  = Join-Path $script:SurfDataDir 'blacklist.txt'
$script:SurfFavouritesFile = Join-Path $script:SurfDataDir 'favourites.txt'
$script:SurfCommandsFile   = Join-Path $script:SurfDataDir 'commands.json'
$script:SurfKeymapFile     = Join-Path $script:SurfDataDir 'keymap.json'

# Expands {dir}, {hovered} and {selected} placeholders in a command template.
# Returns @{ Ok = bool; Text = string; Error = string }.
function Expand-SurfTemplate {
    param(
        [string]$Command,
        [string]$Dir,
        [string]$Hovered,
        [string[]]$Selected = @()
    )
    $text = $Command -replace '\{dir\}', ('"' + $Dir + '"')
    $text = $text -replace '\{hovered\}', ('"' + $Hovered + '"')
    if ($text -match '\{selected\}') {
        if (-not $Selected -or $Selected.Count -eq 0) {
            return @{ Ok = $false; Text = $null; Error = 'Nothing marked - press Space on items first' }
        }
        # comma-joined quoted list: a PowerShell array literal, which cmdlets bind as
        # one parameter and native exes receive as separate arguments
        $joined = '"' + ($Selected -join '","') + '"'
        $text = $text -replace '\{selected\}', $joined
    }
    return @{ Ok = $true; Text = $text; Error = $null }
}

# ---- command store -------------------------------------------------------
# User-defined commands live as a JSON array of {Key, Command, Description, Mode}.

function Get-SurfCommandTable {
    param([string]$Path)
    # emits entries one at a time; collect with @(Get-SurfCommandTable ...).
    # The ForEach-Object flattens PS 5.1's ConvertFrom-Json array wrapping.
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $raw = Get-Content -LiteralPath $Path -Raw
    if (-not $raw.Trim()) { return }
    (ConvertFrom-Json -InputObject $raw) | ForEach-Object { $_ }
}

function Save-SurfCommandTable {
    param([string]$Path, $Table)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Set-Content -LiteralPath $Path -Value (ConvertTo-Json @($Table)) -Encoding UTF8
}

function Add-SurfCommand {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Command,
        [string]$Description,
        [string]$Mode,
        $Keymap
    )
    if (-not $Key -or $Key -notmatch '^[a-z0-9]+$') {
        return @{ Ok = $false; Error = "Keys must be letters and digits only (got '$Key')." }
    }
    $validModes = @('exit', 'contained', 'background', 'pane')
    if ($validModes -notcontains $Mode) {
        return @{ Ok = $false; Error = "Unknown run mode '$Mode'. Valid modes: $($validModes -join ', ')." }
    }
    # built-in keys hold the first-keypress namespace (rebindable via the keymap)
    if (-not $Keymap) { $Keymap = Get-SurfDefaultKeymap }
    $first = $Key.Substring(0, 1)
    $heldBy = $Keymap.Keys | Where-Object { $Keymap[$_] -eq $first }
    if ($heldBy) {
        return @{ Ok = $false; Error = "'$first' is the built-in '$heldBy' key. Choose another key, or rebind the built-in."; BuiltinAction = $heldBy }
    }
    $table = @(Get-SurfCommandTable -Path $Path)
    $existing = $table | Where-Object { $_.Key -eq $Key }
    if ($existing) {
        return @{ Ok = $false; Error = "'$Key' already runs: $($existing.Command). Remove it first (surf remove $Key)." }
    }
    # a key may never be both a command and a chain prefix, in either direction
    $shadowedChains = @($table | Where-Object { $_.Key.Length -gt $Key.Length -and $_.Key.StartsWith($Key) })
    if ($shadowedChains) {
        $list = ($shadowedChains | ForEach-Object { "$($_.Key) ($($_.Command))" }) -join ', '
        return @{ Ok = $false; Error = "'$Key' is already a prefix for: $list. Remove those first or choose another key." }
    }
    $shadowingPrefixes = @($table | Where-Object { $Key.Length -gt $_.Key.Length -and $Key.StartsWith($_.Key) })
    if ($shadowingPrefixes) {
        $list = ($shadowingPrefixes | ForEach-Object { "$($_.Key) ($($_.Command))" }) -join ', '
        return @{ Ok = $false; Error = "'$Key' would be shadowed by existing command: $list. Remove it first or choose another key." }
    }
    $table += [pscustomobject]@{ Key = $Key; Command = $Command; Description = $Description; Mode = $Mode }
    Save-SurfCommandTable -Path $Path -Table $table
    return @{ Ok = $true; Error = $null }
}

# Strips ANSI/VT escape sequences and control characters for one-line previews.
function Remove-SurfAnsi {
    param([string]$Text)
    if (-not $Text) { return '' }
    $esc = [char]27
    # OSC sequences (terminated by BEL or ST), then CSI/other escapes, then control
    # chars. The OSC body excludes ESC as well as BEL so that two OSC sequences on
    # one line cannot swallow the legitimate text between them.
    $t = $Text -replace "$esc\][^`a$esc]*(`a|$esc\\)", ''
    $t = $t -replace "$esc\[[0-9;?]*[ -/]*[@-~]", ''
    $t = $t -replace "$esc[@-_]", ''
    $t = $t -replace '[\x00-\x08\x0B-\x1F\x7F]', ''
    return $t.Trim()
}

# ---- keymap --------------------------------------------------------------
# Built-in letter actions are rebindable; keymap.json stores the full action->key map.

function Get-SurfDefaultKeymap {
    @{ blacklist = 'b'; favourite = 'f'; search = 's'; tab = 't'; quit = 'q'; kill = 'k'; worktrees = 'w' }
}

function Get-SurfKeymap {
    param([string]$Path)
    $km = Get-SurfDefaultKeymap
    $savedNames = @()
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ($raw.Trim()) {
            $saved = ConvertFrom-Json -InputObject $raw
            foreach ($p in $saved.PSObject.Properties) {
                if ($km.ContainsKey($p.Name)) { $km[$p.Name] = $p.Value; $savedNames += $p.Name }
            }
        }
    }
    # explicit (saved) bindings own their keys. A defaulted action whose key was
    # claimed before that action existed (e.g. a pre-0.3.0 keymap.json rebound a
    # built-in to 'k' before kill shipped) moves to a free letter instead of
    # silently double-binding one key to two actions.
    $actions = @('blacklist', 'favourite', 'search', 'tab', 'quit', 'kill', 'worktrees')
    foreach ($action in $actions) {
        if ($savedNames -contains $action) { continue }
        $clash = @($actions | Where-Object { $_ -ne $action -and $km[$_] -eq $km[$action] })
        if ($clash.Count -eq 0) { continue }
        foreach ($candidate in [char[]]'kxzvjnmoiuhgcdelrwypab0123456789') {
            $c = [string]$candidate
            if (@($actions | Where-Object { $km[$_] -eq $c }).Count -eq 0) {
                $km[$action] = $c
                break
            }
        }
    }
    return $km
}

function Set-SurfKeymapBinding {
    param(
        [string]$Path,
        [string]$Action,
        [string]$Key,
        $Commands = @()
    )
    $km = Get-SurfKeymap -Path $Path
    if (-not $km.ContainsKey($Action)) {
        return @{ Ok = $false; Error = "Unknown built-in action '$Action'. Actions: $($km.Keys -join ', ')." }
    }
    if (-not $Key -or $Key -notmatch '^[a-z0-9]$') {
        return @{ Ok = $false; Error = "Built-in keys must be a single letter or digit (got '$Key')." }
    }
    $holder = $km.Keys | Where-Object { $_ -ne $Action -and $km[$_] -eq $Key }
    if ($holder) {
        return @{ Ok = $false; Error = "'$Key' already belongs to the built-in '$holder' action." }
    }
    $clash = @(@($Commands) | Where-Object { $_.Key.StartsWith($Key) })
    if ($clash) {
        $list = ($clash | ForEach-Object { $_.Key }) -join ', '
        return @{ Ok = $false; Error = "'$Key' is used by custom command(s): $list. Remove those first or pick another key." }
    }
    $km[$Action] = $Key
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Set-Content -LiteralPath $Path -Value (ConvertTo-Json $km) -Encoding UTF8
    return @{ Ok = $true; Error = $null }
}

# Key dispatcher: maps a pressed character (plus any pending chain) onto the user's
# command table. Verdicts:
#   run         - exact match; Command holds the entry
#   menu        - the sequence prefixes longer chains; Completions + Pending returned
#   reset       - a pending chain got an invalid continuation
#   passthrough - no pending chain and the key means nothing; built-ins handle it
function Resolve-SurfKey {
    param(
        [string]$KeyChar,
        [string]$Pending = '',
        $Commands
    )
    $seq = $Pending + $KeyChar
    $exact = @($Commands) | Where-Object { $_.Key -eq $seq }
    if ($exact) {
        return @{ Action = 'run'; Command = $exact; Completions = $null; Pending = '' }
    }
    $longer = @(@($Commands) | Where-Object { $_.Key.Length -gt $seq.Length -and $_.Key.StartsWith($seq) })
    if ($longer.Count -gt 0) {
        return @{ Action = 'menu'; Command = $null; Completions = $longer; Pending = $seq }
    }
    if ($Pending) {
        return @{ Action = 'reset'; Command = $null; Completions = $null; Pending = '' }
    }
    return @{ Action = 'passthrough'; Command = $null; Completions = $null; Pending = '' }
}

function Remove-SurfCommand {
    param(
        [string]$Path,
        [string]$Key
    )
    $table = @(Get-SurfCommandTable -Path $Path)
    $match = $table | Where-Object { $_.Key -eq $Key }
    if (-not $match) {
        return @{ Ok = $false; Error = "No command bound to '$Key'." }
    }
    Save-SurfCommandTable -Path $Path -Table @($table | Where-Object { $_.Key -ne $Key })
    return @{ Ok = $true; Error = $null }
}

# ---- git worktrees --------------------------------------------------------
# Pure parsers and planners for the worktree management area. Nothing here
# touches git or the filesystem; the TUI feeds in command output and executes
# the returned plans.

# Parses `git worktree list --porcelain` output. First block is the main
# worktree. Paths come back with git's forward slashes; normalised to Windows.
function ConvertFrom-SurfWorktreeList {
    param(
        [string]$Text,
        [string]$CurrentDir
    )
    $result = @()
    foreach ($block in ($Text -split "(`r`n|`n){2,}")) {
        if ($block -notmatch '(?m)^worktree (.+)$') { continue }
        $wtPath = $Matches[1].Trim().Replace('/', '\')
        $branch = $null
        if ($block -match '(?m)^branch refs/heads/(.+)$') { $branch = $Matches[1].Trim() }
        $result += ,([pscustomobject]@{
            Path      = $wtPath
            Branch    = $branch
            IsMain    = ($result.Count -eq 0)
            IsCurrent = $false
        })
    }
    # the current worktree is the one whose path is the longest prefix of
    # CurrentDir (on a path-segment boundary): a worktree nested inside the
    # main one must win over its container
    if ($CurrentDir) {
        $cur = $CurrentDir.TrimEnd('\')
        $best = $null
        foreach ($wt in $result) {
            $p = $wt.Path.TrimEnd('\')
            $isUnder = $cur.Equals($p, [System.StringComparison]::OrdinalIgnoreCase) -or
                $cur.StartsWith("$p\", [System.StringComparison]::OrdinalIgnoreCase)
            if ($isUnder -and (-not $best -or $p.Length -gt $best.Path.TrimEnd('\').Length)) { $best = $wt }
        }
        if ($best) { $best.IsCurrent = $true }
    }
    return $result
}

# Both branch pickers feed the same UI: entries of {Display, Branch}.

# `gh pr list --json number,title,headRefName` output (gh orders newest first).
function ConvertFrom-SurfPrJson {
    param([string]$Json)
    if (-not $Json -or -not $Json.Trim()) { return @() }
    $prs = ConvertFrom-Json -InputObject $Json
    $result = @()
    foreach ($pr in @($prs)) {
        $result += ,([pscustomobject]@{
            Display = ('#{0} {1} [{2}]' -f $pr.number, $pr.title, $pr.headRefName)
            Branch  = $pr.headRefName
        })
    }
    return $result
}

# `git ls-remote --heads <remote>` output: "<sha>TABrefs/heads/<name>" per line.
function ConvertFrom-SurfRemoteHeads {
    param([string]$Text)
    $branches = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match "`t?refs/heads/(.+)$") { $branches += $Matches[1].Trim() }
    }
    $result = @()
    foreach ($b in ($branches | Sort-Object)) {
        $result += ,([pscustomobject]@{ Display = $b; Branch = $b })
    }
    return $result
}

# Plans a worktree add without touching git. Kind 'local' creates a new branch
# from BaseRef; kind 'remote' checks out Remote's branch, tracking it. Returns
# @{ Ok; Error; WorktreePath; Steps } where Steps is a list of git arg arrays
# for the caller to execute in order.
function Resolve-SurfWorktreeAddPlan {
    param(
        [string]$Kind,
        [string]$BranchName,
        [string]$BaseRef,
        [string]$RepoRoot,
        [string]$RelativePath,
        [string[]]$ExistingBranches = @(),
        [string[]]$ExistingWorktreePaths = @(),
        [string]$Remote = 'origin'
    )
    # the common git check-ref-format rules; git would refuse these anyway, but
    # a footer-sized error beats raw git stderr
    if (-not $BranchName -or -not $BranchName.Trim() -or
        $BranchName -match '[\s~^:?*\[\\]' -or $BranchName -match '\.\.' -or
        $BranchName -match '^[-/]' -or $BranchName -match '[/.]$' -or
        $BranchName -match '\.lock$' -or $BranchName -match '@\{') {
        return @{ Ok = $false; Error = "'$BranchName' is not a valid branch name."; WorktreePath = $null; Steps = $null }
    }
    $clash = @($ExistingBranches | Where-Object { $_ -eq $BranchName })
    if ($clash) {
        return @{ Ok = $false; Error = "A branch named '$BranchName' already exists."; WorktreePath = $null; Steps = $null }
    }
    # blank path = the branch name, with path separators flattened so
    # 'feat/dark-mode' lands in one folder rather than a feat\ subtree
    $rel = if ($RelativePath -and $RelativePath.Trim()) { $RelativePath.Trim() }
           else { $BranchName -replace '[/\\]', '-' }
    $wtPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RepoRoot, $rel))
    $taken = @($ExistingWorktreePaths | Where-Object {
        $_.TrimEnd('\').Equals($wtPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($taken) {
        return @{ Ok = $false; Error = "A worktree already lives at '$wtPath'."; WorktreePath = $null; Steps = $null }
    }
    $steps = @()
    if ($Kind -eq 'local') {
        $steps += ,@('worktree', 'add', '-b', $BranchName, $wtPath, $BaseRef)
    } else {
        $steps += ,@('fetch', $Remote, $BranchName)
        $steps += ,@('worktree', 'add', '--track', '-b', $BranchName, $wtPath, "$Remote/$BranchName")
    }
    return @{ Ok = $true; Error = $null; WorktreePath = $wtPath; Steps = $steps }
}

# Plans a worktree removal: the worktree goes, then its local branch. The
# branch is released-or-abandoned by definition, so -D with no unmerged nag;
# the one guard is uncommitted changes, surfaced as RequiresForce until the
# caller confirms with -Force.
function Resolve-SurfWorktreeRemovePlan {
    param(
        $Worktree,
        [bool]$IsDirty,
        [switch]$Force
    )
    if ($Worktree.IsMain) {
        return @{ Ok = $false; Error = 'The main worktree cannot be removed.'; RequiresForce = $false; Steps = $null }
    }
    if ($IsDirty -and -not $Force) {
        return @{ Ok = $true; Error = $null; RequiresForce = $true; Steps = $null }
    }
    $steps = @()
    if ($IsDirty) { $steps += ,@('worktree', 'remove', '--force', $Worktree.Path) }
    else { $steps += ,@('worktree', 'remove', $Worktree.Path) }
    if ($Worktree.Branch) { $steps += ,@('branch', '-D', $Worktree.Branch) }
    return @{ Ok = $true; Error = $null; RequiresForce = $false; Steps = $steps }
}

# The one choke point that shells out to git. -C keeps surf's own location out
# of it; stderr merges into Output so callers get git's words on failure.
function Invoke-SurfGit {
    param([string]$Dir, [string[]]$GitArgs)
    try {
        $out = & git -C $Dir @GitArgs 2>&1
        $lines = @($out | ForEach-Object { "$_" })
        return @{ Ok = ($LASTEXITCODE -eq 0); Output = ($lines -join "`n"); ExitCode = $LASTEXITCODE }
    } catch {
        return @{ Ok = $false; Output = $_.Exception.Message; ExitCode = -1 }
    }
}

# Cheap repo test: walk up looking for a .git directory (main worktree) or
# .git file (linked worktree) so directories outside any repo never pay for a
# git process launch.
function Find-SurfGitMarker {
    param([string]$Dir)
    $d = $Dir
    while ($d) {
        if (Test-Path -LiteralPath (Join-Path $d '.git')) { return $d }
        $d = [System.IO.Path]::GetDirectoryName($d)
    }
    return $null
}

# Worktree state for a directory: $null when not inside a git repo. -Prune
# first drops stale registrations so ghost entries never surface.
function Get-SurfWorktreeState {
    param([string]$Dir, [switch]$Prune)
    if (-not (Find-SurfGitMarker -Dir $Dir)) { return $null }
    if ($Prune) { $null = Invoke-SurfGit -Dir $Dir -GitArgs @('worktree', 'prune') }
    $r = Invoke-SurfGit -Dir $Dir -GitArgs @('worktree', 'list', '--porcelain')
    if (-not $r.Ok) { return $null }
    $wts = @(ConvertFrom-SurfWorktreeList -Text $r.Output -CurrentDir $Dir)
    if ($wts.Count -eq 0) { return $null }
    return @{ MainRoot = $wts[0].Path; Worktrees = $wts }
}

function Get-SurfLocalBranches {
    param([string]$Dir)
    $r = Invoke-SurfGit -Dir $Dir -GitArgs @('for-each-ref', 'refs/heads', '--format=%(refname:short)')
    if (-not $r.Ok) { return @() }
    return @($r.Output -split "`r?`n" | Where-Object { $_.Trim() })
}

# "Latest master": fetch origin, then origin/HEAD -> origin/main -> origin/master;
# with no remote, fall back to the local default branch. $null when nothing fits.
function Resolve-SurfDefaultBase {
    param([string]$Dir)
    $remotes = Invoke-SurfGit -Dir $Dir -GitArgs @('remote')
    if ($remotes.Ok -and $remotes.Output.Trim()) {
        $null = Invoke-SurfGit -Dir $Dir -GitArgs @('fetch', 'origin')
        $head = Invoke-SurfGit -Dir $Dir -GitArgs @('rev-parse', '--abbrev-ref', 'origin/HEAD')
        if ($head.Ok -and $head.Output.Trim() -match '^origin/.') { return $head.Output.Trim() }
        foreach ($cand in @('origin/main', 'origin/master')) {
            $v = Invoke-SurfGit -Dir $Dir -GitArgs @('rev-parse', '--verify', '--quiet', $cand)
            if ($v.Ok) { return $cand }
        }
    }
    foreach ($cand in @('main', 'master')) {
        $v = Invoke-SurfGit -Dir $Dir -GitArgs @('rev-parse', '--verify', '--quiet', $cand)
        if ($v.Ok) { return $cand }
    }
    return $null
}

# Branch picker source: open PRs via gh when it's installed and works,
# otherwise every remote branch. Returns @{ Entries; Source } with Source
# 'pr' or 'remote' so the UI can title the list honestly.
function Get-SurfBranchPicker {
    param([string]$Dir)
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        try {
            Push-Location -LiteralPath $Dir
            $json = & gh pr list --state open --limit 100 --json number,title,headRefName 2>$null
            $ghOk = ($LASTEXITCODE -eq 0)
        } catch { $ghOk = $false } finally { Pop-Location }
        if ($ghOk) {
            $entries = @(ConvertFrom-SurfPrJson -Json ($json -join "`n"))
            if ($entries.Count -gt 0) { return @{ Entries = $entries; Source = 'pr' } }
        }
    }
    $r = Invoke-SurfGit -Dir $Dir -GitArgs @('ls-remote', '--heads', 'origin')
    if (-not $r.Ok) { return @{ Entries = @(); Source = 'remote' } }
    return @{ Entries = @(ConvertFrom-SurfRemoteHeads -Text $r.Output); Source = 'remote' }
}

function surf {
    param(
        [Parameter(Position = 0)][string]$Command,
        [Parameter(Position = 1)][string]$Key,
        [Parameter(Position = 2)][string]$CommandText,
        [switch]$Exit,
        [switch]$Contained,
        [switch]$Background,
        [switch]$Pane
    )

    function New-SurfEntry($name, $kind, $full, $fav, $date) {
        [pscustomobject]@{ Name = $name; Kind = $kind; FullPath = $full; Fav = [bool]$fav; Date = $date }
    }

    function Get-SurfBlacklist {
        if (Test-Path -LiteralPath $script:SurfBlacklistFile) {
            @(Get-Content -LiteralPath $script:SurfBlacklistFile | Where-Object { $_.Trim() })
        } else { @() }
    }

    function Save-SurfBlacklist($paths) {
        if (-not (Test-Path -LiteralPath $script:SurfDataDir)) {
            New-Item -ItemType Directory -Path $script:SurfDataDir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:SurfBlacklistFile -Value (@($paths) -join "`r`n") -Encoding UTF8
    }

    function Get-SurfFavourites {
        if (Test-Path -LiteralPath $script:SurfFavouritesFile) {
            @(Get-Content -LiteralPath $script:SurfFavouritesFile | Where-Object { $_.Trim() })
        } else { @() }
    }

    function Save-SurfFavourites($paths) {
        if (-not (Test-Path -LiteralPath $script:SurfDataDir)) {
            New-Item -ItemType Directory -Path $script:SurfDataDir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:SurfFavouritesFile -Value (@($paths) -join "`r`n") -Encoding UTF8
    }

    # Listing: ". (stay here)" first, then folders A-Z (minus blacklisted), then files A-Z (greyed).
    # Favourites float to the top. If anything in this directory is blacklisted, a virtual
    # "surf-blocklist" folder sits at the bottom.
    function Get-SurfListing($dir) {
        $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add((New-SurfEntry '.  (stay here)' 'self' $dir))
        # background processes pin above everything; FullPath is the working dir so
        # {hovered} and T stay meaningful on these rows
        foreach ($pe in $procTable.ToArray()) {
            $state = if ($pe.Job.HasExited) { "exited($($pe.Job.ExitCode))" } else { 'running' }
            $preview = Remove-SurfAnsi $pe.Job.LastLine
            $label = "$state  $($pe.Title)"
            if ($preview) { $label += "   $preview" }
            $list.Add(([pscustomobject]@{ Name = $label; Kind = 'proc'; FullPath = $pe.Job.WorkingDirectory; Fav = $false; Date = $null; Proc = $pe }))
        }
        # Space-marked items pin to a visible group up top; local ones leave the
        # normal sections so nothing appears twice
        foreach ($m in @($marks)) {
            $name = if ([System.IO.Path]::GetDirectoryName($m) -eq $dir) { [System.IO.Path]::GetFileName($m) } else { $m }
            $list.Add((New-SurfEntry $name 'mark' $m))
        }
        # inside a repo with linked worktrees, a glanceable group: which
        # worktrees exist and which one we're in. Navigation only - add/remove
        # live in the management area (the worktrees key).
        $ws = Get-SurfWorktreeState -Dir $dir
        if ($ws -and @($ws.Worktrees).Count -gt 1) {
            $list.Add((New-SurfEntry ('worktrees ({0})' -f @($ws.Worktrees).Count) 'none' ''))
            foreach ($row in (Get-SurfWorktreeRowEntries $ws)) { $list.Add($row) }
        }
        $blDirs = 0; $blFiles = 0
        $favD = @(); $normD = @(); $favF = @(); $normF = @()
        foreach ($d in @($items | Where-Object { $_.PSIsContainer } | Sort-Object Name)) {
            if ($marks -contains $d.FullName) { continue }
            if ($blacklist -contains $d.FullName) { $blDirs++; continue }
            if ($favourites -contains $d.FullName) { $favD += ,(New-SurfEntry $d.Name 'dir' $d.FullName $true) }
            else { $normD += ,(New-SurfEntry $d.Name 'dir' $d.FullName) }
        }
        foreach ($f in @($items | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)) {
            if ($marks -contains $f.FullName) { continue }
            if ($blacklist -contains $f.FullName) { $blFiles++; continue }
            if ($favourites -contains $f.FullName) { $favF += ,(New-SurfEntry $f.Name 'file' $f.FullName $true $f.LastWriteTime) }
            else { $normF += ,(New-SurfEntry $f.Name 'file' $f.FullName $false $f.LastWriteTime) }
        }
        foreach ($e in ($favD + $favF + $normD + $normF)) { $list.Add($e) }
        if ($blDirs -gt 0 -or $blFiles -gt 0) {
            $label = 'surf-blocklist  ({0} folder{1}, {2} file{3})' -f `
                $blDirs, $(if ($blDirs -ne 1) { 's' }), $blFiles, $(if ($blFiles -ne 1) { 's' })
            $list.Add((New-SurfEntry $label 'blfolder' $dir))
        }
        return ,$list
    }

    # One row per worktree: "leaf [branch]" with main/here markers. Used by the
    # browse group and the management area alike; FullPath keeps Enter, T and
    # {hovered} meaningful on these rows.
    function Get-SurfWorktreeRowEntries($state) {
        $rows = @()
        foreach ($wt in @($state.Worktrees)) {
            $leaf = [System.IO.Path]::GetFileName($wt.Path)
            if (-not $leaf) { $leaf = $wt.Path }
            $branch = if ($wt.Branch) { $wt.Branch } else { 'detached' }
            $name = "$leaf [$branch]"
            if ($wt.IsMain) { $name += '  (main)' }
            if ($wt.IsCurrent) { $name += '  (here)' }
            $rows += ,([pscustomobject]@{ Name = $name; Kind = 'wt'; FullPath = $wt.Path; Fav = $false; Date = $null; Wt = $wt })
        }
        return ,$rows
    }

    function Get-SurfWorktreeMenuEntries($state) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($row in (Get-SurfWorktreeRowEntries $state)) { $list.Add($row) }
        return ,$list
    }

    function Get-SurfDrives {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($d in @(Get-PSDrive -PSProvider FileSystem | Sort-Object Name)) {
            if (-not $d.Root) { continue }
            $label = $d.Root
            if ($null -ne $d.Free) { $label += ('  ({0:N0} GB free)' -f ($d.Free / 1GB)) }
            $list.Add((New-SurfEntry $label 'drive' $d.Root))
        }
        return ,$list
    }

    # $scope = $null for the full blacklist, or a directory to show only its direct children
    function Get-SurfBlacklistEntries($scope) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($p in @($blacklist | Sort-Object)) {
            if ($scope -and [System.IO.Path]::GetDirectoryName($p) -ne $scope) { continue }
            $name = if ($scope) { [System.IO.Path]::GetFileName($p) } else { $p }
            if (Test-Path -LiteralPath $p -PathType Leaf) { $name += '  (file)' }
            elseif (-not (Test-Path -LiteralPath $p -PathType Container)) { $name += '  (missing)' }
            $list.Add((New-SurfEntry $name 'bl' $p))
        }
        if ($list.Count -eq 0) {
            $empty = if ($scope) { '(nothing blocked here)' } else { '(blacklist is empty)' }
            $list.Add((New-SurfEntry $empty 'none' ''))
        }
        return ,$list
    }

    $mode      = 'browse'                # 'browse', 'drives', 'blacklist', 'search-input' or 'results'
    $path      = (Get-Location).Path
    $prevPath  = $path                   # where to return from the drive picker
    $cursor    = 0
    $scroll    = 0
    $message   = ''
    $blacklist = @(Get-SurfBlacklist)
    $searchQuery = ''
    $searchPrev  = $null                 # {Mode, Entries, Cursor, Scroll} to restore on search cancel
    $blScope     = $null                 # directory the blacklist view is scoped to ($null = full list)
    $favourites  = @(Get-SurfFavourites)
    $confirmDelete = $null               # entry awaiting Y/N delete confirmation
    $marks       = @()                   # Space-marked full paths (session-scoped)
    $customCommands = @(Get-SurfCommandTable -Path $script:SurfCommandsFile)
    $keymap      = Get-SurfKeymap -Path $script:SurfKeymapFile
    $jumpPending = $false                # '/' pressed, next key jumps
    $pendingRun  = $null                 # exit-mode command to run after the TUI closes
    $chainPending = ''                   # keys typed so far into a chain (which-key menu showing)
    $helpPrev    = $null                 # view to restore when the ? overlay closes
    $procTable   = New-Object System.Collections.Generic.List[object]   # background SurfJobs, session-scoped
    $confirmQuit = $null                 # pending exit awaiting Y/N because processes are running
    $wtState     = $null                 # repo worktree state while the management area is open
    $wtPrev      = $null                 # view to restore when the management area closes
    $wtFlow      = $null                 # chained add prompts: @{Kind; Stage; Branch; Base; Input}
    $confirmWt   = $null                 # worktree removal awaiting Y/N: @{Wt; Stage}

    function Test-SurfProcsRunning {
        foreach ($pe in $procTable) { if (-not $pe.Job.HasExited) { return $true } }
        return $false
    }

    function Get-SurfHelpEntries {
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add((New-SurfEntry 'Built-in keys' 'none' ''))
        $list.Add((New-SurfEntry '  Up/Down move   Right enter   Left up   Enter cd   Space mark' 'none' ''))
        $list.Add((New-SurfEntry ('  {0} favourite   {1} blacklist   {2} new tab   {3} search' -f `
            $keymap.favourite.ToUpper(), $keymap.blacklist.ToUpper(), $keymap.tab.ToUpper(), $keymap.search.ToUpper()) 'none' ''))
        $list.Add((New-SurfEntry ('  / jump   Del delete   ? help   Esc/{0} quit' -f $keymap.quit.ToUpper()) 'none' ''))
        $list.Add((New-SurfEntry ('  {0} worktrees (in a git repo): Enter browse   N new local   R remote/PR   D remove worktree+branch' -f $keymap.worktrees.ToUpper()) 'none' ''))
        $list.Add((New-SurfEntry ('  process rows: Enter attach   {0} kill/dismiss   (attached: Ctrl+C stop, Esc Esc detach, PgUp history)' -f $keymap.kill.ToUpper()) 'none' ''))
        $list.Add((New-SurfEntry '' 'none' ''))
        $list.Add((New-SurfEntry 'Custom commands  (surf add <key> "<command>", surf remove <key>)' 'none' ''))
        if ($customCommands.Count -eq 0) {
            $list.Add((New-SurfEntry '  (none yet)' 'none' ''))
        } else {
            foreach ($c in ($customCommands | Sort-Object Key)) {
                $list.Add((New-SurfEntry ('  {0,-6} {1,-38} {2,-11} {3}' -f $c.Key, $c.Command, "($($c.Mode))", $c.Description) 'none' ''))
            }
        }
        $list.Add((New-SurfEntry '' 'none' ''))
        $list.Add((New-SurfEntry 'Placeholders: {hovered} cursor item   {selected} marked items   {dir} viewed folder' 'none' ''))
        return ,$list
    }

    # Attach view: full-screen live tail of a background process with stdin forwarding.
    # Reserved keys: Ctrl+C kill-tree, Esc-Esc detach (single Esc forwards after 400ms),
    # PgUp/PgDn/Home/End scrollback. Returns a status message for the footer.
    function Invoke-SurfAttach($job) {
        $prevCtrlC = [Console]::TreatControlCAsInput
        $status = 'Detached - process still running'
        try {
            [Console]::TreatControlCAsInput = $true
            [Console]::CursorVisible = $true
            Clear-Host
            $vtOk = [Surf.SurfConsole]::EnableVt()
            Write-Host (" attached: $($job.CommandText)") -ForegroundColor Black -BackgroundColor Cyan
            Write-Host ' type to send input (Enter sends the line)   Ctrl+C stop   Esc Esc detach   PgUp history' -ForegroundColor DarkGray
            Write-Host ''
            $next = [Math]::Max($job.FirstIndex, $job.TotalLines - 30)
            $pendingEsc = $false
            $escWatch = New-Object System.Diagnostics.Stopwatch
            $inputBuf = ''
            $tailShown = ''
            $scrollTop = [long]-1        # -1 = live tail; otherwise absolute top index of the history view
            $banner = $false

            while ($true) {
                # ---- 1) drain every buffered key before rendering, so a flooding ----
                # ---- child can never starve Ctrl+C or double-Esc                 ----
                while ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)

                    if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                        $pendingEsc = $false
                        $job.KillTree()
                        $status = 'Stopped'
                        continue   # keep draining output until the exit banner
                    }
                    if ($key.Key -eq [ConsoleKey]::Escape) {
                        if ($scrollTop -ge 0) {
                            # Esc leaves history mode; it is never a detach half-press here
                            $scrollTop = -1
                            Clear-Host
                            Write-Host (" attached: $($job.CommandText)") -ForegroundColor Black -BackgroundColor Cyan
                            Write-Host ' type to send input (Enter sends the line)   Ctrl+C stop   Esc Esc detach   PgUp history' -ForegroundColor DarkGray
                            Write-Host ''
                            $next = [Math]::Max($job.FirstIndex, $job.TotalLines - 30)
                            $tailShown = ''
                            if ($banner) { $banner = $false }   # banner reprints via the drained check below
                            continue
                        }
                        if ($banner -or $pendingEsc) {
                            while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
                            return $status
                        }
                        $pendingEsc = $true
                        $escWatch.Restart()
                        continue
                    }
                    if ($key.Key -in @([ConsoleKey]::PageUp, [ConsoleKey]::PageDown, [ConsoleKey]::Home, [ConsoleKey]::End)) {
                        $pendingEsc = $false
                        $page = [Math]::Max(5, $Host.UI.RawUI.WindowSize.Height - 3)
                        $total = $job.TotalLines
                        $first = $job.FirstIndex
                        $wasScrolled = $scrollTop
                        switch ($key.Key) {
                            'PageUp'   { $scrollTop = if ($scrollTop -lt 0) { [Math]::Max($first, $total - 2 * $page) } else { [Math]::Max($first, $scrollTop - $page) } }
                            'Home'     { $scrollTop = $first }
                            'PageDown' { if ($scrollTop -ge 0) { $scrollTop += $page; if ($scrollTop + $page -ge $total) { $scrollTop = -1 } } }
                            'End'      { $scrollTop = -1 }
                        }
                        if ($wasScrolled -lt 0 -and $scrollTop -lt 0) { continue }   # PgDn/End while live: no-op
                        if ($scrollTop -ge 0) {
                            # frozen history view, ANSI stripped so row widths stay sane
                            Clear-Host
                            $w = $Host.UI.RawUI.WindowSize.Width
                            Write-Host (" history $scrollTop-$([Math]::Min($scrollTop + $page, $total)) of $total   PgUp/PgDn/Home/End   any other key: back to live".PadRight($w - 1)) -ForegroundColor Black -BackgroundColor DarkYellow
                            $slice = $job.SnapshotLines($scrollTop)
                            for ($si = 0; $si -lt [Math]::Min($page, $slice.Length); $si++) {
                                Write-Host (Remove-SurfAnsi $slice[$si])
                            }
                        } else {
                            # back to live: repaint header and resume the tail
                            Clear-Host
                            Write-Host (" attached: $($job.CommandText)") -ForegroundColor Black -BackgroundColor Cyan
                            Write-Host ' type to send input (Enter sends the line)   Ctrl+C stop   Esc Esc detach   PgUp history' -ForegroundColor DarkGray
                            Write-Host ''
                            $next = [Math]::Max($job.FirstIndex, $job.TotalLines - 30)
                            $tailShown = ''
                            $banner = $false   # the drained check below re-prints it
                        }
                        continue
                    }

                    # past the banner, any remaining key leaves - drained so buffered
                    # type-ahead can't leak into the browse loop
                    if ($banner) {
                        while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
                        return $status
                    }

                    # any other key: a deferred Esc flushes to the child first (order kept)
                    if ($pendingEsc) {
                        $null = $job.WriteInputRaw([string][char]27)
                        $pendingEsc = $false
                    }
                    if ($scrollTop -ge 0) {
                        # leave history mode; the key itself is deliberately discarded
                        $scrollTop = -1
                        Clear-Host
                        Write-Host (" attached: $($job.CommandText)") -ForegroundColor Black -BackgroundColor Cyan
                        Write-Host ' type to send input (Enter sends the line)   Ctrl+C stop   Esc Esc detach   PgUp history' -ForegroundColor DarkGray
                        Write-Host ''
                        $next = [Math]::Max($job.FirstIndex, $job.TotalLines - 30)
                        $tailShown = ''
                        continue
                    }
                    if ($key.Key -eq [ConsoleKey]::Enter) {
                        if ($tailShown) { [Console]::Write("`r" + (' ' * $tailShown.Length) + "`r") }
                        [Console]::WriteLine((Remove-SurfAnsi $job.PartialLine) + $inputBuf)
                        $tailShown = ''
                        if (-not $job.WriteInputLine($inputBuf)) { $status = 'Process ended' }
                        $inputBuf = ''
                    } elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                        if ($inputBuf.Length -gt 0) { $inputBuf = $inputBuf.Substring(0, $inputBuf.Length - 1) }
                    } elseif ($key.Key -eq [ConsoleKey]::Tab) {
                        $inputBuf += "`t"
                    } elseif ($key.KeyChar -and [int]$key.KeyChar -ge 32) {
                        $inputBuf += $key.KeyChar
                    }
                }

                # a lone Esc past the detach window belongs to the child
                if ($pendingEsc -and $escWatch.ElapsedMilliseconds -gt 400) {
                    $null = $job.WriteInputRaw([string][char]27)
                    $pendingEsc = $false
                }

                if ($scrollTop -lt 0) {
                    # ---- 2) live tail: completed lines, capped per frame ----
                    $first = $job.FirstIndex
                    $total = $job.TotalLines
                    if ($next -lt $first) {
                        if ($tailShown) { [Console]::Write("`r" + (' ' * $tailShown.Length) + "`r"); $tailShown = '' }
                        [Console]::WriteLine("[... $($first - $next) earlier lines dropped]")
                        $next = $first
                    }
                    if ($total -gt $next) {
                        if ($tailShown) { [Console]::Write("`r" + (' ' * $tailShown.Length) + "`r"); $tailShown = '' }
                        if ($total - $next -gt 300) {
                            [Console]::WriteLine("[... skipping $($total - $next - 200) lines ...]")
                            $next = $total - 200
                        }
                        foreach ($ln in $job.SnapshotLines($next)) {
                            if ($vtOk) { [Console]::WriteLine($ln) } else { [Console]::WriteLine((Remove-SurfAnsi $ln)) }
                        }
                        $next = $total
                    }
                    # ---- 3) the unterminated tail (prompts) + locally typed input,
                    # ---- clamped to the console width: a wrapped tail would break
                    # ---- the carriage-return clearing math
                    $desired = (Remove-SurfAnsi $job.PartialLine) + $inputBuf
                    $maxTail = [Math]::Max(10, $Host.UI.RawUI.WindowSize.Width - 2)
                    if ($desired.Length -gt $maxTail) {
                        $desired = '...' + $desired.Substring($desired.Length - ($maxTail - 3))
                    }
                    if ($desired -ne $tailShown) {
                        $clear = [Math]::Max($tailShown.Length, 0)
                        [Console]::Write("`r" + (' ' * $clear) + "`r" + $desired)
                        $tailShown = $desired
                    }
                    # ---- 4) exit banner once everything has drained ----
                    if (-not $banner -and $job.HasDrained -and $job.TotalLines -le $next) {
                        if ($tailShown) { [Console]::Write("`r" + (' ' * $tailShown.Length) + "`r"); $tailShown = '' }
                        [Console]::WriteLine('')
                        [Console]::WriteLine("[exited (code $($job.ExitCode))]  PgUp for history, any other key to return")
                        if ($status -eq 'Detached - process still running') {
                            $status = "Exited (code $($job.ExitCode))"
                        }
                        $banner = $true
                    }
                }

                Start-Sleep -Milliseconds 15
            }
        } finally {
            [Console]::TreatControlCAsInput = $prevCtrlC
            [Console]::CursorVisible = $false
        }
    }

    # Dot-invoked: closes the worktree management area back to the prior view.
    # A browse view is rebuilt rather than restored - add/remove changed it.
    $CloseWorktreeArea = {
        if ($wtPrev -and $wtPrev.Mode -ne 'browse') {
            $mode = $wtPrev.Mode; $entries = $wtPrev.Entries
            $cursor = $wtPrev.Cursor; $scroll = $wtPrev.Scroll
        } else {
            try { $entries = Get-SurfListing $path } catch { }
            $mode = 'browse'; $cursor = 0; $scroll = 0
        }
        $wtPrev = $null; $wtState = $null; $wtFlow = $null
    }

    # Dot-invoked (. $RunCustomCommand) so assignments land in this scope.
    # Expects $cmdToRun; sets $pendingRun for exit mode, runs contained inline.
    $RunCustomCommand = {
        $exp = Expand-SurfTemplate -Command $cmdToRun.Command -Dir $path `
            -Hovered $entries[$cursor].FullPath -Selected @($marks)
        if (-not $exp.Ok) {
            $message = $exp.Error
        } elseif ($cmdToRun.Mode -eq 'exit') {
            $pendingRun = @{ Text = $exp.Text; Dir = $path }
        } elseif ($cmdToRun.Mode -eq 'background') {
            try {
                # match the hosting edition so PS7 users' commands run under pwsh
                $launcher = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
                $job = New-Object Surf.SurfJob($exp.Text, $path, $launcher)
                $procTable.Add(@{ Job = $job; Title = $cmdToRun.Command })
                $message = "Started in background: $($cmdToRun.Command)"
                if ($cmdToRun.Command -match '\{selected\}') { $marks = @() }
                if ($mode -eq 'browse') { try { $entries = Get-SurfListing $path } catch { } }
            } catch {
                $message = "Could not start: $($_.Exception.Message)"
            }
        } elseif ($cmdToRun.Mode -eq 'pane') {
            try {
                $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($exp.Text))
                if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
                    $dirArg = $path
                    if ($dirArg -match '\s') {
                        if ($dirArg.EndsWith('\')) { $dirArg += '\' }
                        $dirArg = "`"$dirArg`""
                    }
                    # -w 0 targets the most-recently-used WT window - normally the one
                    # surf lives in, but not guaranteed if another WT window was focused
                    Start-Process wt.exe -ArgumentList @('-w', '0', 'sp', '-d', $dirArg, 'powershell', '-NoProfile', '-NoExit', '-EncodedCommand', $b64)
                    $message = "Opened in pane: $($cmdToRun.Command)"
                } else {
                    Start-Process powershell.exe -WorkingDirectory $path -ArgumentList @('-NoProfile', '-NoExit', '-EncodedCommand', $b64)
                    $message = "Opened in new window: $($cmdToRun.Command)"
                }
                if ($cmdToRun.Command -match '\{selected\}') { $marks = @() }
            } catch {
                $message = "Could not open pane: $($_.Exception.Message)"
            }
        } else {
            # contained: hand the console to the command, then reclaim it
            Clear-Host
            [Console]::CursorVisible = $true
            Write-Host "> $($exp.Text)" -ForegroundColor DarkCyan
            # no piping/capture: a pipe makes native tools think they have no TTY,
            # so they buffer output and drop colors - let them own the console.
            # UTF-8 while they do: node tools emit UTF-8 and the default OEM
            # codepage renders their checkmarks as mojibake.
            Push-Location -LiteralPath $path
            $prevEnc = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                Invoke-Expression $exp.Text
            }
            catch { $_ | Out-Host }
            finally {
                try { [Console]::OutputEncoding = $prevEnc } catch { }
                Pop-Location
            }
            [Console]::CursorVisible = $false
            Write-Host ''
            Write-Host ' Press any key to return to surf...' -ForegroundColor DarkGray
            $null = [Console]::ReadKey($true)
            # a command that consumed the marked set clears it
            if ($cmdToRun.Command -match '\{selected\}') { $marks = @() }
            if ($mode -eq 'browse') { try { $entries = Get-SurfListing $path } catch { } }
            $cursor = [Math]::Min($cursor, [Math]::Max(0, $entries.Count - 1))
            $lastW = -1   # force a full clear + redraw
        }
    }

    if ($Command -and $Command -ne 'blacklist') {
        switch ($Command) {
            'add' {
                if (-not $Key -or -not $CommandText) {
                    Write-Warning 'Usage: surf add <key> "<command>" [-Exit | -Contained | -Background | -Pane]'
                    return
                }
                $desc = Read-Host 'Description (optional, shown in surf help)'
                $runMode = if ($Exit) { 'exit' }
                           elseif ($Contained) { 'contained' }
                           elseif ($Background) { 'background' }
                           elseif ($Pane) { 'pane' }
                           else {
                               Write-Host 'Run mode:'
                               Write-Host '  e - exit surf, run in the terminal (interactive / long-running)'
                               Write-Host '  c - contained: run inside surf, show output, return to browsing'
                               Write-Host '  b - background: keep browsing, process pinned in the listing'
                               Write-Host '  p - pane: open in a Windows Terminal split (full TUIs like claude)'
                               $ans = Read-Host 'Choose [e/c/b/p]'
                               switch -Regex ($ans) {
                                   '^c' { 'contained'; break }
                                   '^b' { 'background'; break }
                                   '^p' { 'pane'; break }
                                   default { 'exit' }
                               }
                           }
                $kmCli = Get-SurfKeymap -Path $script:SurfKeymapFile
                $r = Add-SurfCommand -Path $script:SurfCommandsFile -Key $Key.ToLower() -Command $CommandText -Description $desc -Mode $runMode -Keymap $kmCli
                if (-not $r.Ok -and $r.BuiltinAction) {
                    # offer to relocate the built-in so the user's key wins
                    Write-Warning $r.Error
                    $first = $Key.ToLower().Substring(0, 1)
                    $ans = Read-Host "Move the built-in '$($r.BuiltinAction)' to a different key and give '$first' to your command? [y/N]"
                    if ($ans -match '^y') {
                        $newKey = (Read-Host "New key for built-in '$($r.BuiltinAction)'").ToLower()
                        $cmds = @(Get-SurfCommandTable -Path $script:SurfCommandsFile)
                        $kr = Set-SurfKeymapBinding -Path $script:SurfKeymapFile -Action $r.BuiltinAction -Key $newKey -Commands $cmds
                        if (-not $kr.Ok) { Write-Warning $kr.Error; return }
                        Write-Host "Built-in '$($r.BuiltinAction)' is now on '$($newKey.ToUpper())'" -ForegroundColor Yellow
                        $kmCli = Get-SurfKeymap -Path $script:SurfKeymapFile
                        $r = Add-SurfCommand -Path $script:SurfCommandsFile -Key $Key.ToLower() -Command $CommandText -Description $desc -Mode $runMode -Keymap $kmCli
                    }
                }
                if ($r.Ok) { Write-Host "Added: press '$($Key.ToLower())' in surf to run '$CommandText' ($runMode)" -ForegroundColor Green }
                elseif (-not $r.BuiltinAction -or $r.Error) { Write-Warning $r.Error }
                return
            }
            'remove' {
                if (-not $Key) { Write-Warning 'Usage: surf remove <key>'; return }
                $r = Remove-SurfCommand -Path $script:SurfCommandsFile -Key $Key.ToLower()
                if ($r.Ok) { Write-Host "Removed '$($Key.ToLower())'" -ForegroundColor Green }
                else { Write-Warning $r.Error }
                return
            }
            'help' {
                $km = Get-SurfKeymap -Path $script:SurfKeymapFile
                Write-Host 'Built-in keys:' -ForegroundColor Cyan
                Write-Host '  Up/Down move   Right enter   Left up   Enter cd   Space mark   / jump   ? help'
                Write-Host ('  {0} favourite   {1} blacklist   {2} new tab   {3} search   Del delete   Esc/{4} quit' -f `
                    $km.favourite.ToUpper(), $km.blacklist.ToUpper(), $km.tab.ToUpper(), $km.search.ToUpper(), $km.quit.ToUpper())
                Write-Host ('  On a process row: Enter attach   {0} kill/dismiss. Attached: Ctrl+C stop, Esc Esc detach, PgUp history' -f $km.kill.ToUpper())
                Write-Host ('  {0} worktrees (in a git repo): Enter browse   N new local   R checkout remote/PR   D remove worktree+branch' -f $km.worktrees.ToUpper())
                Write-Host ''
                Write-Host 'Custom commands:' -ForegroundColor Cyan
                $cmds = @(Get-SurfCommandTable -Path $script:SurfCommandsFile)
                if ($cmds.Count -eq 0) {
                    Write-Host '  (none yet - add one with: surf add <key> "<command>")'
                } else {
                    foreach ($c in ($cmds | Sort-Object Key)) {
                        $line = '  {0,-6} {1,-40} {2,-10} {3}' -f $c.Key, $c.Command, "($($c.Mode))", $c.Description
                        Write-Host $line
                    }
                }
                Write-Host ''
                Write-Host 'Placeholders: {hovered} = item under cursor, {selected} = Space-marked items, {dir} = viewed folder'
                return
            }
            default {
                Write-Warning "surf: unknown command '$Command' (try: surf add | remove | help | blacklist)"
                return
            }
        }
    }

    if ($Command -eq 'blacklist') {
        $mode = 'blacklist'
        $entries = Get-SurfBlacklistEntries
    } else {
        try {
            $entries = Get-SurfListing $path
        } catch {
            Write-Warning "surf: cannot read '$path': $($_.Exception.Message)"
            return
        }
    }

    $cursorWasVisible = $true
    try { $cursorWasVisible = [Console]::CursorVisible } catch { }

    try {
        [Console]::CursorVisible = $false
        Clear-Host
        $lastW = -1; $lastH = -1

        :main while ($true) {
            # ---- render -------------------------------------------------
            $size = $Host.UI.RawUI.WindowSize
            $w = [Math]::Max(20, $size.Width)
            $h = [Math]::Max(6, $size.Height)
            if ($w -ne $lastW -or $h -ne $lastH) { Clear-Host; $lastW = $w; $lastH = $h }

            $rows = [Math]::Max(1, $h - 3)
            if ($cursor -lt $scroll) { $scroll = $cursor }
            if ($cursor -ge $scroll + $rows) { $scroll = $cursor - $rows + 1 }

            [Console]::SetCursorPosition(0, 0)

            $title = switch ($mode) {
                'drives'    { 'Drives' }
                'blacklist' { if ($blScope) { "surf-blocklist: $blScope" } else { 'Blacklist' } }
                'results'   { "Search '$searchQuery': $path" }
                'help'      { 'Help' }
                'worktrees' { "Worktrees: $($wtState.MainRoot)" }
                'wt-input'  { "Worktrees: $($wtState.MainRoot)" }
                'wt-pick'   { if ($wtFlow -and $wtFlow.Source -eq 'pr') { 'Open pull requests' } else { 'Remote branches' } }
                default     { $path }
            }
            $pos = "($($cursor + 1)/$($entries.Count))"
            $maxTitle = $w - $pos.Length - 5
            if ($title.Length -gt $maxTitle) {
                $title = '...' + $title.Substring($title.Length - $maxTitle + 3)
            }
            Write-Host (" $title  $pos".PadRight($w - 1)) -ForegroundColor Cyan

            for ($r = 0; $r -lt $rows; $r++) {
                $i = $scroll + $r
                if ($i -lt $entries.Count) {
                    $e = $entries[$i]
                    $label = if ($e.Kind -eq 'dir') { "$($e.Name)\" } else { $e.Name }
                    $line = if ($e.Kind -eq 'proc') { " > $label" }
                            elseif ($e.Kind -eq 'mark') { " + $label" }
                            elseif ($e.Fav) { " * $label" }
                            else { "   $label" }
                    # files carry their modified date, right-aligned at the screen edge
                    $date = if ($e.Kind -eq 'file' -and $e.Date) { $e.Date.ToString('g') } else { '' }
                    if ($i -eq $cursor) {
                        # arrow + enter-symbol hint on the hovered row; built from char codes
                        # because literal unicode garbles under PS 5.1's ANSI script parsing.
                        # Only shown where Enter actually does something (not files).
                        $hint = ''
                        $arrow = [char]0x2192; $ret = [char]0x21B5
                        if ($e.Kind -eq 'self') { $hint = "  $ret CD into" }
                        elseif ($e.Kind -eq 'proc') {
                            $hint = if ($e.Proc.Job.HasExited) { "  $ret attach  $($keymap.kill.ToUpper()) dismiss" }
                                    else { "  $ret attach  $($keymap.kill.ToUpper()) kill" }
                        }
                        elseif ($e.Kind -eq 'blfolder') { $hint = "  $arrow $ret open" }
                        elseif ($e.Kind -eq 'mark') {
                            if (Test-Path -LiteralPath $e.FullPath -PathType Container) { $hint = "  $arrow navigate  $ret CD into" }
                            else { $hint = '  Space un-mark' }
                        }
                        elseif ($e.Kind -eq 'wt') {
                            if ($mode -eq 'worktrees') { $hint = "  $ret browse" }
                            else { $hint = "  $arrow navigate  $ret CD into" }
                        }
                        elseif ($e.Kind -eq 'wtpick') { $hint = "  $ret checkout" }
                        elseif ($e.Kind -ne 'file' -and $e.Kind -ne 'none') {
                            $hint = "  $arrow navigate  $ret CD into"
                        }
                        $reserved = $hint.Length + $(if ($date) { $date.Length + 3 } else { 0 })
                        $max = $w - 1 - $reserved
                        if ($line.Length -gt $max) { $line = $line.Substring(0, [Math]::Max(0, $max - 3)) + '...' }
                        $line = $line + $hint
                        $line = if ($date) { $line.PadRight($w - 2 - $date.Length) + $date + ' ' }
                                else { $line.PadRight($w - 1) }
                        Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
                        continue
                    }
                    if ($date) {
                        $max = $w - 4 - $date.Length
                        if ($line.Length -gt $max) { $line = $line.Substring(0, [Math]::Max(0, $max - 3)) + '...' }
                        $line = $line.PadRight($w - 2 - $date.Length) + $date + ' '
                    } else {
                        if ($line.Length -gt $w - 1) { $line = $line.Substring(0, $w - 4) + '...' }
                        $line = $line.PadRight($w - 1)
                    }
                    if ($e.Kind -eq 'proc') {
                        if ($e.Proc.Job.HasExited) { Write-Host $line -ForegroundColor DarkGray }
                        else { Write-Host $line -ForegroundColor Green }
                    } elseif ($e.Kind -eq 'mark') {
                        Write-Host $line -ForegroundColor Magenta
                    } elseif ($e.Kind -eq 'wt') {
                        Write-Host $line -ForegroundColor Cyan
                    } elseif ($e.Fav) {
                        Write-Host $line -ForegroundColor Yellow
                    } elseif ($e.Kind -eq 'file' -or $e.Kind -eq 'none') {
                        Write-Host $line -ForegroundColor DarkGray
                    } elseif ($e.Kind -eq 'self') {
                        Write-Host $line -ForegroundColor DarkCyan
                    } elseif ($e.Kind -eq 'blfolder') {
                        Write-Host $line -ForegroundColor DarkYellow
                    } else {
                        Write-Host $line -ForegroundColor White
                    }
                } else {
                    Write-Host (' ' * ($w - 1))
                }
            }

            # which-key menu: chain completions drawn over the bottom rows of the list
            if ($chainPending) {
                $comps = @($customCommands |
                    Where-Object { $_.Key.Length -gt $chainPending.Length -and $_.Key.StartsWith($chainPending) } |
                    Sort-Object Key)
                $menuRows = [Math]::Min($comps.Count + 1, $rows)
                [Console]::SetCursorPosition(0, 1 + $rows - $menuRows)
                Write-Host ((" [$chainPending] which key next?").PadRight($w - 1)) -ForegroundColor Black -BackgroundColor DarkYellow
                for ($mi = 0; $mi -lt $menuRows - 1; $mi++) {
                    $c = $comps[$mi]
                    $mline = '   {0}   {1}' -f $c.Key.Substring($chainPending.Length), $c.Command
                    if ($c.Description) { $mline += "   - $($c.Description)" }
                    if ($mline.Length -gt $w - 1) { $mline = $mline.Substring(0, $w - 4) + '...' }
                    Write-Host ($mline.PadRight($w - 1)) -ForegroundColor White -BackgroundColor DarkGray
                }
                [Console]::SetCursorPosition(0, 1 + $rows)
            }

            $footer = if ($confirmQuit) { " $((@($procTable | Where-Object { -not $_.Job.HasExited })).Count) process(es) running - stop them and leave?   Y / N" }
                      elseif ($confirmDelete) { " Delete '$($confirmDelete.Name)' (to Recycle Bin)?   Y / N" }
                      elseif ($confirmWt) {
                          $wtLeaf = [System.IO.Path]::GetFileName($confirmWt.Wt.Path)
                          if ($confirmWt.Stage -eq 'force') { " '$wtLeaf' has uncommitted changes - remove anyway?   Y / N" }
                          elseif ($confirmWt.Wt.Branch) { " Remove worktree '$wtLeaf' and delete branch '$($confirmWt.Wt.Branch)'?   Y / N" }
                          else { " Remove worktree '$wtLeaf'?   Y / N" }
                      }
                      elseif ($mode -eq 'wt-input') {
                          switch ($wtFlow.Stage) {
                              'branch' { " New branch name: $($wtFlow.Input)" + '_   (Enter next, Esc back)' }
                              'base'   { " Base ref: $($wtFlow.Input)" + '_   (Enter = latest default branch, Esc back)' }
                              default  { " Path (relative to repo root): $($wtFlow.Input)" + '_   (Enter create, Esc back)' }
                          }
                      }
                      elseif ($mode -eq 'search-input') { " Search: $searchQuery" + '_   (Enter search, Esc cancel)' }
                      elseif ($chainPending) { " chain [$chainPending]   press the next key   Esc cancel" }
                      elseif ($message) { " $message" }
                      elseif ($mode -eq 'help') { ' Up/Dn scroll   any other key to return' }
                      elseif ($mode -eq 'blacklist' -and $blScope) { " Up/Dn   -> browse   <-/Esc back   Enter cd   $($keymap.blacklist.ToUpper()) un-list   $($keymap.tab.ToUpper()) tab   $($keymap.quit.ToUpper()) quit" }
                      elseif ($mode -eq 'blacklist') { " Up/Dn   -> browse   Enter cd   $($keymap.blacklist.ToUpper()) un-list   $($keymap.tab.ToUpper()) tab   Esc/$($keymap.quit.ToUpper()) quit" }
                      elseif ($mode -eq 'results') { " Up/Dn   -> browse   <-/Esc back   Enter cd   $($keymap.blacklist.ToUpper()) blacklist   $($keymap.tab.ToUpper()) tab   $($keymap.quit.ToUpper()) quit" }
                      elseif ($mode -eq 'worktrees') { " Up/Dn   Enter browse   N new local   R remote/PR   D remove   Esc/$($keymap.worktrees.ToUpper()) back   $($keymap.quit.ToUpper()) quit" }
                      elseif ($mode -eq 'wt-pick') { ' Up/Dn   Enter checkout into new worktree   Esc back' }
                      else { " Up/Dn   -> in   <- up   Enter cd   Space mark   / jump   $($keymap.search.ToUpper()) search   $($keymap.favourite.ToUpper()) fav   $($keymap.blacklist.ToUpper()) blacklist   $($keymap.tab.ToUpper()) tab   ? help   $($keymap.quit.ToUpper()) quit" }
            if ($marks.Count -gt 0 -and -not $confirmDelete -and $mode -ne 'search-input') {
                $footer += "   [$($marks.Count) marked]"
            }
            if ($footer.Length -gt $w - 1) { $footer = $footer.Substring(0, $w - 1) }
            $footerColor = if ($confirmDelete -or $confirmQuit -or $confirmWt) { 'Yellow' } else { 'DarkGray' }
            Write-Host ($footer.PadRight($w - 1)) -ForegroundColor $footerColor -NoNewline

            # ---- input --------------------------------------------------
            # with processes running, poll so previews stay live; otherwise block so
            # an idle surf costs nothing
            if ($procTable.Count -gt 0 -and $mode -eq 'browse' -and
                -not ($confirmDelete -or $confirmQuit -or $jumpPending -or $chainPending)) {
                $waitedMs = 0
                while (-not [Console]::KeyAvailable -and $waitedMs -lt 500) {
                    Start-Sleep -Milliseconds 50
                    $waitedMs += 50
                }
                if (-not [Console]::KeyAvailable) {
                    # silent refresh: keep the hovered item under the cursor even if
                    # background jobs created/removed files, and keep $message shown
                    $anchor = if ($entries.Count -gt 0 -and $cursor -lt $entries.Count) { $entries[$cursor] } else { $null }
                    try {
                        $entries = Get-SurfListing $path
                        $cursor = [Math]::Min($cursor, $entries.Count - 1)
                        if ($anchor) {
                            for ($j = 0; $j -lt $entries.Count; $j++) {
                                $cand = $entries[$j]
                                if ($cand.Kind -ne $anchor.Kind) { continue }
                                if ($cand.Kind -eq 'proc') {
                                    if ($cand.Proc -eq $anchor.Proc) { $cursor = $j; break }
                                } elseif ($cand.FullPath -eq $anchor.FullPath) { $cursor = $j; break }
                            }
                        }
                    } catch { }
                    continue
                }
            }
            $k = [Console]::ReadKey($true)
            $message = ''   # a real keypress consumes the footer message; poll refreshes keep it

            if ($jumpPending) {
                # '/' was pressed: this key jumps to the next folder starting with it
                $jumpPending = $false
                $ch = $k.KeyChar
                if ($ch -and [char]::IsLetterOrDigit($ch)) {
                    $n = $entries.Count
                    for ($step = 1; $step -le $n; $step++) {
                        $j = ($cursor + $step) % $n
                        $e2 = $entries[$j]
                        if (($e2.Kind -eq 'dir' -or $e2.Kind -eq 'drive') -and $e2.Name.Length -gt 0 -and
                            [char]::ToLowerInvariant($e2.Name[0]) -eq [char]::ToLowerInvariant($ch)) {
                            $cursor = $j
                            break
                        }
                    }
                }
                continue
            }

            if ($confirmDelete) {
                if ($k.Key -eq 'Y') {
                    $target = $confirmDelete
                    $confirmDelete = $null
                    try {
                        # VB FileIO gives us real Recycle Bin deletion on 5.1 and 7
                        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
                        if (Test-Path -LiteralPath $target.FullPath -PathType Container) {
                            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($target.FullPath, 'OnlyErrorDialogs', 'SendToRecycleBin')
                        } else {
                            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($target.FullPath, 'OnlyErrorDialogs', 'SendToRecycleBin')
                        }
                        # drop dangling references to the deleted path
                        if ($favourites -contains $target.FullPath) {
                            $favourites = @($favourites | Where-Object { $_ -ne $target.FullPath })
                            Save-SurfFavourites $favourites
                        }
                        if ($blacklist -contains $target.FullPath) {
                            $blacklist = @($blacklist | Where-Object { $_ -ne $target.FullPath })
                            Save-SurfBlacklist $blacklist
                        }
                        $message = "Deleted to Recycle Bin: $($target.Name)"
                        if ($mode -eq 'browse') {
                            try { $entries = Get-SurfListing $path } catch { }
                        } elseif ($mode -eq 'results') {
                            $entries = @($entries | Where-Object {
                                $_.FullPath -ne $target.FullPath -and -not $_.FullPath.StartsWith("$($target.FullPath)\", [System.StringComparison]::OrdinalIgnoreCase)
                            })
                            if ($entries.Count -eq 0) {
                                try { $entries = Get-SurfListing $path } catch { }
                                $mode = 'browse'
                            }
                        }
                        $cursor = [Math]::Min($cursor, [Math]::Max(0, $entries.Count - 1))
                    } catch {
                        $message = "Delete failed: $($_.Exception.Message)"
                    }
                } else {
                    $confirmDelete = $null
                    $message = 'Delete cancelled'
                }
                continue
            }

            if ($confirmQuit) {
                if ($k.Key -eq 'Y') {
                    $cq = $confirmQuit
                    $confirmQuit = $null
                    foreach ($pe in $procTable.ToArray()) {
                        try { $pe.Job.KillTree() } catch { }
                        try { $pe.Job.Dispose() } catch { }
                    }
                    $procTable.Clear()
                    switch ($cq.Action) {
                        'cd'  { Set-Location -LiteralPath $cq.Target; return }
                        'run' { break main }
                        default { return }
                    }
                } else {
                    $confirmQuit = $null
                    $pendingRun = $null
                    $message = 'Processes kept running'
                }
                continue
            }

            if ($confirmWt) {
                if ($k.Key -eq 'Y') {
                    $wtTarget = $confirmWt.Wt
                    $doForce = ($confirmWt.Stage -eq 'force')
                    $isDirty = $doForce
                    if (-not $doForce) {
                        $st = Invoke-SurfGit -Dir $wtTarget.Path -GitArgs @('status', '--porcelain')
                        $isDirty = [bool]($st.Ok -and $st.Output.Trim())
                        if ($isDirty) {
                            # escalate to the explicit unsaved-changes confirm
                            $confirmWt.Stage = 'force'
                            continue
                        }
                    }
                    $confirmWt = $null
                    $plan = Resolve-SurfWorktreeRemovePlan -Worktree $wtTarget -IsDirty $isDirty -Force:$doForce
                    if (-not $plan.Ok) { $message = $plan.Error; continue }
                    $mainRoot = $wtState.MainRoot
                    # removing the worktree we're standing in: land in the main
                    # worktree first, both surf's view and the process cwd (a dir
                    # that is someone's cwd cannot be deleted on Windows)
                    $wtTrim = $wtTarget.Path.TrimEnd('\')
                    $procCwd = (Get-Location).Path.TrimEnd('\')
                    if ($procCwd.Equals($wtTrim, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $procCwd.StartsWith("$wtTrim\", [System.StringComparison]::OrdinalIgnoreCase)) {
                        Set-Location -LiteralPath $mainRoot
                    }
                    $pathTrim = $path.TrimEnd('\')
                    if ($pathTrim.Equals($wtTrim, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $pathTrim.StartsWith("$wtTrim\", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $path = $mainRoot
                    }
                    [Console]::SetCursorPosition(0, $rows + 1)
                    Write-Host (' Removing worktree...'.PadRight($w - 1)) -ForegroundColor Yellow -NoNewline
                    $failed = $null
                    foreach ($step in $plan.Steps) {
                        $r = Invoke-SurfGit -Dir $mainRoot -GitArgs $step
                        if (-not $r.Ok) {
                            $failed = @(($r.Output -split "`r?`n") | Where-Object { $_.Trim() })[0]
                            break
                        }
                    }
                    $wtState = Get-SurfWorktreeState -Dir $mainRoot -Prune
                    if ($mode -eq 'worktrees' -and $wtState) {
                        $entries = Get-SurfWorktreeMenuEntries $wtState
                        $cursor = [Math]::Min($cursor, [Math]::Max(0, $entries.Count - 1))
                    }
                    if ($failed) { $message = "Remove failed: $failed" }
                    else {
                        $wtLeaf = [System.IO.Path]::GetFileName($wtTarget.Path)
                        if ($wtTarget.Branch) { $message = "Removed worktree '$wtLeaf' and branch '$($wtTarget.Branch)'" }
                        else { $message = "Removed worktree '$wtLeaf'" }
                    }
                } else {
                    $confirmWt = $null
                    $message = 'Removal cancelled'
                }
                continue
            }

            if ($mode -eq 'search-input') {
                switch ($k.Key) {
                    'Escape' {
                        # restore whatever we were looking at before the search prompt
                        $mode = $searchPrev.Mode; $entries = $searchPrev.Entries
                        $cursor = $searchPrev.Cursor; $scroll = $searchPrev.Scroll
                        $searchQuery = ''
                    }
                    'Backspace' {
                        if ($searchQuery.Length -gt 0) { $searchQuery = $searchQuery.Substring(0, $searchQuery.Length - 1) }
                    }
                    'Enter' {
                        if (-not $searchQuery) {
                            $mode = $searchPrev.Mode; $entries = $searchPrev.Entries
                            $cursor = $searchPrev.Cursor; $scroll = $searchPrev.Scroll
                        } else {
                            [Console]::SetCursorPosition(0, $rows + 1)
                            Write-Host (' Searching...'.PadRight($w - 1)) -ForegroundColor Yellow -NoNewline
                            $found = @(Get-ChildItem -LiteralPath $path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                                Where-Object {
                                    if ($_.Name -notlike "*$searchQuery*") { return $false }
                                    $full = $_.FullName
                                    foreach ($blp in $blacklist) {
                                        if ($full -eq $blp -or $full.StartsWith("$blp\", [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
                                    }
                                    $true
                                } | Select-Object -First 200)
                            if ($found.Count -eq 0) {
                                $mode = $searchPrev.Mode; $entries = $searchPrev.Entries
                                $cursor = $searchPrev.Cursor; $scroll = $searchPrev.Scroll
                                $message = "No folders matching '$searchQuery'"
                            } else {
                                $list = New-Object System.Collections.Generic.List[object]
                                foreach ($d in $found) {
                                    $rel = $d.FullName.Substring($path.Length).TrimStart('\')
                                    $list.Add((New-SurfEntry $rel 'dir' $d.FullName ($favourites -contains $d.FullName)))
                                }
                                $entries = $list
                                $mode = 'results'
                                $cursor = 0; $scroll = 0
                                if ($found.Count -ge 200) { $message = 'Showing first 200 matches' }
                            }
                        }
                    }
                    default {
                        $ch = $k.KeyChar
                        if ($ch -and [int]$ch -ge 32) { $searchQuery += $ch }
                    }
                }
                continue
            }

            if ($mode -eq 'wt-input') {
                switch ($k.Key) {
                    'Escape' {
                        # one prompt back per press
                        if ($wtFlow.Stage -eq 'path' -and $wtFlow.Kind -eq 'local') {
                            $wtFlow.Stage = 'base'; $wtFlow.Input = $wtFlow.BaseTyped
                        } elseif ($wtFlow.Stage -eq 'path') {
                            $entries = $wtFlow.Picker
                            $mode = 'wt-pick'; $cursor = 0; $scroll = 0
                        } elseif ($wtFlow.Stage -eq 'base') {
                            $wtFlow.Stage = 'branch'; $wtFlow.Input = $wtFlow.Branch
                        } else {
                            $wtFlow = $null
                            $mode = 'worktrees'
                        }
                    }
                    'Backspace' {
                        if ($wtFlow.Input.Length -gt 0) { $wtFlow.Input = $wtFlow.Input.Substring(0, $wtFlow.Input.Length - 1) }
                    }
                    'Enter' {
                        if ($wtFlow.Stage -eq 'branch') {
                            $name = $wtFlow.Input.Trim()
                            # the planner owns branch-name rules; probe it now so a bad
                            # name fails here, not three prompts later
                            $probe = Resolve-SurfWorktreeAddPlan -Kind 'local' -BranchName $name -BaseRef 'HEAD' `
                                -RepoRoot $wtState.MainRoot -RelativePath 'surf-probe' `
                                -ExistingBranches (Get-SurfLocalBranches -Dir $path)
                            if (-not $probe.Ok) { $message = $probe.Error }
                            else { $wtFlow.Branch = $name; $wtFlow.Stage = 'base'; $wtFlow.Input = '' }
                        } elseif ($wtFlow.Stage -eq 'base') {
                            $typed = $wtFlow.Input.Trim()
                            $wtFlow.BaseTyped = $typed
                            if ($typed) { $wtFlow.Base = $typed }
                            else {
                                [Console]::SetCursorPosition(0, $rows + 1)
                                Write-Host (' Fetching origin...'.PadRight($w - 1)) -ForegroundColor Yellow -NoNewline
                                $wtFlow.Base = Resolve-SurfDefaultBase -Dir $path
                            }
                            if (-not $wtFlow.Base) { $message = 'No default branch found - type a base ref' }
                            else { $wtFlow.Stage = 'path'; $wtFlow.Input = ($wtFlow.Branch -replace '[/\\]', '-') }
                        } else {
                            $existingWt = @()
                            foreach ($x in @($wtState.Worktrees)) { $existingWt += $x.Path }
                            $plan = Resolve-SurfWorktreeAddPlan -Kind $wtFlow.Kind -BranchName $wtFlow.Branch `
                                -BaseRef $wtFlow.Base -RepoRoot $wtState.MainRoot -RelativePath $wtFlow.Input `
                                -ExistingBranches (Get-SurfLocalBranches -Dir $path) -ExistingWorktreePaths $existingWt
                            if (-not $plan.Ok) { $message = $plan.Error }
                            else {
                                [Console]::SetCursorPosition(0, $rows + 1)
                                Write-Host (' Creating worktree...'.PadRight($w - 1)) -ForegroundColor Yellow -NoNewline
                                $failed = $null
                                foreach ($step in $plan.Steps) {
                                    $r = Invoke-SurfGit -Dir $wtState.MainRoot -GitArgs $step
                                    if (-not $r.Ok) {
                                        $failed = @(($r.Output -split "`r?`n") | Where-Object { $_.Trim() })[0]
                                        break
                                    }
                                }
                                # back to the list, staying where we were (the new
                                # worktree appears as a row rather than yanking us in)
                                $wtFlow = $null
                                $wtState = Get-SurfWorktreeState -Dir $path -Prune
                                $entries = Get-SurfWorktreeMenuEntries $wtState
                                $mode = 'worktrees'; $cursor = 0; $scroll = 0
                                if ($failed) { $message = "Create failed: $failed" }
                                else { $message = "Created worktree: $($plan.WorktreePath)" }
                            }
                        }
                    }
                    default {
                        $ch = $k.KeyChar
                        if ($ch -and [int]$ch -ge 32) { $wtFlow.Input += $ch }
                    }
                }
                continue
            }

            # help overlay: navigation keys scroll it, anything else closes it
            if ($mode -eq 'help' -and $k.Key -notin @('UpArrow', 'DownArrow', 'PageUp', 'PageDown', 'Home', 'End')) {
                $mode = $helpPrev.Mode; $entries = $helpPrev.Entries
                $cursor = $helpPrev.Cursor; $scroll = $helpPrev.Scroll
                continue
            }

            # worktree management area: Enter browses in, N/R/D mutate, Esc/W close.
            # Arrow and paging keys fall through to the shared handlers below.
            if ($mode -eq 'worktrees') {
                if ($k.Key -eq 'Enter') {
                    $e = $entries[$cursor]
                    if ($e.Kind -eq 'wt') {
                        try {
                            $entries = Get-SurfListing $e.FullPath
                            $path = $e.FullPath
                            $mode = 'browse'; $cursor = 0; $scroll = 0
                            $wtPrev = $null; $wtState = $null
                        } catch { $message = "Cannot open: $($e.Name)" }
                    }
                    continue
                }
                if ($k.Key -eq 'Escape') { . $CloseWorktreeArea; continue }
                $chW = if ($k.KeyChar -and [char]::IsLetterOrDigit($k.KeyChar)) { ([string]$k.KeyChar).ToLower() } else { $null }
                if ($chW) {
                    if ($chW -eq 'n') {
                        $wtFlow = @{ Kind = 'local'; Stage = 'branch'; Branch = ''; Base = $null; BaseTyped = ''; Input = ''; Source = ''; Picker = $null }
                        $mode = 'wt-input'
                    } elseif ($chW -eq 'r') {
                        [Console]::SetCursorPosition(0, $rows + 1)
                        Write-Host (' Loading branches...'.PadRight($w - 1)) -ForegroundColor Yellow -NoNewline
                        $picker = Get-SurfBranchPicker -Dir $path
                        if (@($picker.Entries).Count -eq 0) {
                            $message = 'No open PRs or remote branches found'
                        } else {
                            $list = New-Object System.Collections.Generic.List[object]
                            foreach ($p in @($picker.Entries)) {
                                $list.Add(([pscustomobject]@{ Name = $p.Display; Kind = 'wtpick'; FullPath = ''; Fav = $false; Date = $null; Branch = $p.Branch }))
                            }
                            $wtFlow = @{ Kind = 'remote'; Stage = 'pick'; Branch = ''; Base = $null; BaseTyped = ''; Input = ''; Source = $picker.Source; Picker = $list }
                            $entries = $list
                            $mode = 'wt-pick'; $cursor = 0; $scroll = 0
                        }
                    } elseif ($chW -eq 'd') {
                        $e = $entries[$cursor]
                        if ($e.Kind -eq 'wt') {
                            if ($e.Wt.IsMain) { $message = 'The main worktree cannot be removed' }
                            else { $confirmWt = @{ Wt = $e.Wt; Stage = 'confirm' } }
                        }
                    } elseif ($chW -eq $keymap.worktrees) {
                        . $CloseWorktreeArea
                    } elseif ($chW -eq $keymap.quit) {
                        if (Test-SurfProcsRunning) { $confirmQuit = @{ Action = 'quit' } } else { return }
                    }
                    continue
                }
            }

            # remote branch / PR picker: Enter selects, Esc backs out
            if ($mode -eq 'wt-pick') {
                if ($k.Key -eq 'Enter') {
                    $sel = $entries[$cursor]
                    if ($sel.Kind -eq 'wtpick') {
                        $wtFlow.Branch = $sel.Branch
                        $wtFlow.Stage = 'path'
                        $wtFlow.Input = ($sel.Branch -replace '[/\\]', '-')
                        $entries = Get-SurfWorktreeMenuEntries $wtState
                        $mode = 'wt-input'; $cursor = 0; $scroll = 0
                    }
                    continue
                }
                if ($k.Key -eq 'Escape' -or $k.Key -eq 'LeftArrow') {
                    $wtFlow = $null
                    $entries = Get-SurfWorktreeMenuEntries $wtState
                    $mode = 'worktrees'; $cursor = 0; $scroll = 0
                    continue
                }
                if ($k.KeyChar -and [int]$k.KeyChar -ge 32) { continue }
            }

            # a which-key menu is open: the next letter walks the chain, anything else cancels
            if ($chainPending) {
                $chainChar = if ($k.KeyChar -and [char]::IsLetterOrDigit($k.KeyChar)) { ([string]$k.KeyChar).ToLower() } else { $null }
                if ($chainChar) {
                    $verdict = Resolve-SurfKey -KeyChar $chainChar -Pending $chainPending -Commands $customCommands
                    $chainPending = $verdict.Pending
                    if ($verdict.Action -eq 'run') {
                        $cmdToRun = $verdict.Command
                        . $RunCustomCommand
                        if ($pendingRun) {
                            if (Test-SurfProcsRunning) { $confirmQuit = @{ Action = 'run' } }
                            else { break main }
                        }
                    } elseif ($verdict.Action -eq 'reset') {
                        $message = 'No such chain'
                    }
                } else {
                    $chainPending = ''
                }
                continue
            }

            # letters resolve in three layers: custom commands, then chains, then built-ins
            $chL = if ($k.KeyChar -and [char]::IsLetterOrDigit($k.KeyChar)) { ([string]$k.KeyChar).ToLower() } else { $null }
            if ($chL) {
                # on a process row the kill key outranks even custom commands, so a
                # pre-existing custom binding on this letter can't make kill unreachable
                if ($entries[$cursor].Kind -eq 'proc' -and $chL -eq $keymap.kill) {
                    $pe = $entries[$cursor].Proc
                    if ($pe.Job.HasExited) {
                        try { $pe.Job.Dispose() } catch { }
                        $null = $procTable.Remove($pe)
                        $message = "Dismissed: $($pe.Title)"
                    } else {
                        try { $pe.Job.KillTree() } catch { }
                        $message = "Stopped: $($pe.Title)"
                    }
                    try {
                        $entries = Get-SurfListing $path
                        $cursor = [Math]::Min($cursor, $entries.Count - 1)
                    } catch { }
                    continue
                }
                $dispatched = $false
                if ($mode -eq 'browse' -or $mode -eq 'results') {
                    $verdict = Resolve-SurfKey -KeyChar $chL -Commands $customCommands
                    if ($verdict.Action -eq 'run') {
                        $cmdToRun = $verdict.Command
                        . $RunCustomCommand
                        if ($pendingRun) {
                            if (Test-SurfProcsRunning) { $confirmQuit = @{ Action = 'run' } }
                            else { break main }
                        }
                        $dispatched = $true
                    } elseif ($verdict.Action -eq 'menu') {
                        $chainPending = $verdict.Pending
                        $dispatched = $true
                    }
                }
                if (-not $dispatched) {
                    $builtinAction = $null
                    foreach ($a in @($keymap.Keys)) { if ($keymap[$a] -eq $chL) { $builtinAction = $a; break } }
                    switch ($builtinAction) {
                        'quit' {
                            if (Test-SurfProcsRunning) { $confirmQuit = @{ Action = 'quit' } }
                            else { return }
                        }

                        'kill' {
                            $message = "$($keymap.kill.ToUpper()) stops a background process - hover one in the pinned group"
                        }

                        'search' {
                            if ($mode -eq 'browse' -or $mode -eq 'results') {
                                $searchPrev = @{ Mode = $mode; Entries = $entries; Cursor = $cursor; Scroll = $scroll }
                                $mode = 'search-input'
                                $searchQuery = ''
                            }
                        }

                        'blacklist' {
                            $e = $entries[$cursor]
                            if ($mode -eq 'blacklist') {
                                if ($e.Kind -eq 'bl') {
                                    $blacklist = @($blacklist | Where-Object { $_ -ne $e.FullPath })
                                    Save-SurfBlacklist $blacklist
                                    $entries = Get-SurfBlacklistEntries $blScope
                                    if ($blScope -and $entries[0].Kind -eq 'none') {
                                        # scoped view emptied: drop back to browsing with the item restored
                                        try { $entries = Get-SurfListing $path } catch { }
                                        $mode = 'browse'; $blScope = $null
                                    }
                                    $cursor = [Math]::Min($cursor, $entries.Count - 1)
                                    $message = "Un-listed: $($e.FullPath)"
                                }
                            } elseif ($mode -eq 'browse' -or $mode -eq 'results') {
                                if ($e.Kind -eq 'dir' -or $e.Kind -eq 'file') {
                                    $blacklist = @($blacklist) + $e.FullPath
                                    Save-SurfBlacklist $blacklist
                                    if ($mode -eq 'browse') {
                                        try { $entries = Get-SurfListing $path } catch { }
                                    } else {
                                        # drop the blacklisted folder and anything under it from the results
                                        $entries = @($entries | Where-Object {
                                            $_.FullPath -ne $e.FullPath -and -not $_.FullPath.StartsWith("$($e.FullPath)\", [System.StringComparison]::OrdinalIgnoreCase)
                                        })
                                        if ($entries.Count -eq 0) {
                                            try { $entries = Get-SurfListing $path } catch { }
                                            $mode = 'browse'
                                        }
                                    }
                                    $cursor = [Math]::Min($cursor, $entries.Count - 1)
                                    $message = "Blacklisted: $($e.Name)  (manage with 'surf blacklist')"
                                } else {
                                    $message = 'This entry cannot be blacklisted'
                                }
                            } else {
                                $message = 'Drives cannot be blacklisted'
                            }
                        }

                        'favourite' {
                            $e = $entries[$cursor]
                            if (($mode -eq 'browse' -or $mode -eq 'results') -and ($e.Kind -eq 'dir' -or $e.Kind -eq 'file')) {
                                if ($favourites -contains $e.FullPath) {
                                    $favourites = @($favourites | Where-Object { $_ -ne $e.FullPath })
                                    $message = "Un-favourited: $($e.Name)"
                                } else {
                                    $favourites = @($favourites) + $e.FullPath
                                    $message = "Favourited: $($e.Name)"
                                }
                                Save-SurfFavourites $favourites
                                if ($mode -eq 'browse') {
                                    try {
                                        $entries = Get-SurfListing $path
                                        # follow the item to its new position
                                        $cursor = [Math]::Min($cursor, $entries.Count - 1)
                                        for ($j = 0; $j -lt $entries.Count; $j++) {
                                            if ($entries[$j].FullPath -eq $e.FullPath -and $entries[$j].Kind -eq $e.Kind) { $cursor = $j; break }
                                        }
                                    } catch { }
                                } else {
                                    $e.Fav = -not $e.Fav
                                }
                            } else {
                                $message = 'Only folders and files can be favourited'
                            }
                        }

                        'tab' {
                            $e = $entries[$cursor]
                            $target = if ($e.Kind -eq 'self') { $path } else { $e.FullPath }
                            if ($e.Kind -eq 'file' -or $e.Kind -eq 'none') {
                                $message = 'Not a folder'
                            } elseif (-not (Test-Path -LiteralPath $target -PathType Container)) {
                                $message = 'Folder no longer exists'
                            } else {
                                try {
                                    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
                                        # quote only when needed; a trailing \ before a closing quote
                                        # would escape it, so double it
                                        $dirArg = $target
                                        if ($dirArg -match '\s') {
                                            if ($dirArg.EndsWith('\')) { $dirArg += '\' }
                                            $dirArg = "`"$dirArg`""
                                        }
                                        Start-Process wt.exe -ArgumentList @('-w', '0', 'nt', '-d', $dirArg)
                                        $message = "Opened in new tab: $target"
                                    } else {
                                        Start-Process powershell.exe -WorkingDirectory $target
                                        $message = "Opened new window: $target"
                                    }
                                } catch { $message = "Could not open terminal: $($_.Exception.Message)" }
                            }
                        }

                        'worktrees' {
                            if ($mode -eq 'browse' -or $mode -eq 'results') {
                                $ws = Get-SurfWorktreeState -Dir $path -Prune
                                if (-not $ws) { $message = 'Not inside a git repository' }
                                else {
                                    $wtState = $ws
                                    $wtPrev = @{ Mode = $mode; Entries = $entries; Cursor = $cursor; Scroll = $scroll }
                                    $entries = Get-SurfWorktreeMenuEntries $wtState
                                    $mode = 'worktrees'; $cursor = 0; $scroll = 0
                                    # pre-select the worktree we're standing in
                                    for ($j = 0; $j -lt $entries.Count; $j++) {
                                        if ($entries[$j].Wt.IsCurrent) { $cursor = $j; break }
                                    }
                                }
                            }
                        }
                    }
                }
                continue
            }

            switch ($k.Key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $entries.Count - 1) { $cursor++ } }
                'Home'      { $cursor = 0 }
                'End'       { $cursor = $entries.Count - 1 }
                'PageUp'    { $cursor = [Math]::Max(0, $cursor - $rows) }
                'PageDown'  { $cursor = [Math]::Min($entries.Count - 1, $cursor + $rows) }

                'RightArrow' {
                    $e = $entries[$cursor]
                    if ($e.Kind -eq 'blfolder') {
                        $blScope = $e.FullPath
                        $entries = Get-SurfBlacklistEntries $blScope
                        $mode = 'blacklist'
                        $cursor = 0; $scroll = 0
                    } elseif ($e.Kind -eq 'bl' -and -not (Test-Path -LiteralPath $e.FullPath -PathType Container)) {
                        $message = 'Not a folder - un-list with B'
                    } elseif ($e.Kind -eq 'dir' -or $e.Kind -eq 'drive' -or $e.Kind -eq 'bl' -or $e.Kind -eq 'wt') {
                        try {
                            $entries = Get-SurfListing $e.FullPath
                            $path = $e.FullPath
                            $mode = 'browse'
                            $cursor = 0; $scroll = 0
                            $wtPrev = $null; $wtState = $null
                        } catch {
                            $message = "Cannot open: $($e.Name)"
                        }
                    } elseif ($e.Kind -eq 'file') {
                        $message = 'Not a folder'
                    }
                }

                'LeftArrow' {
                    if ($mode -eq 'results' -or ($mode -eq 'blacklist' -and $blScope)) {
                        try { $entries = Get-SurfListing $path } catch { }
                        $mode = 'browse'; $blScope = $null; $cursor = 0; $scroll = 0
                    } elseif ($mode -eq 'drives') {
                        # back out of the drive picker to where we were
                        try {
                            $entries = Get-SurfListing $prevPath
                            $path = $prevPath
                            $mode = 'browse'
                            $cursor = 0; $scroll = 0
                        } catch { $message = 'Cannot return to previous folder' }
                    } elseif ($mode -eq 'browse') {
                        $parent = [System.IO.Path]::GetDirectoryName($path)
                        if ([string]::IsNullOrEmpty($parent)) {
                            # at a drive root: show the drive picker
                            $prevPath = $path
                            $entries = Get-SurfDrives
                            $mode = 'drives'
                            $cursor = 0; $scroll = 0
                            for ($j = 0; $j -lt $entries.Count; $j++) {
                                if ($path -like "$($entries[$j].FullPath)*") { $cursor = $j; break }
                            }
                        } else {
                            $child = [System.IO.Path]::GetFileName($path)
                            try {
                                $entries = Get-SurfListing $parent
                                $path = $parent
                                $cursor = 0; $scroll = 0
                                # land on the folder we just came from
                                for ($j = 0; $j -lt $entries.Count; $j++) {
                                    if ($entries[$j].Kind -eq 'dir' -and $entries[$j].Name -eq $child) { $cursor = $j; break }
                                }
                            } catch { $message = 'Access denied: parent folder' }
                        }
                    }
                }

                'Enter' {
                    $e = $entries[$cursor]
                    if ($e.Kind -eq 'file') { $message = 'Files are not selectable' }
                    elseif ($e.Kind -eq 'none') { }
                    elseif ($e.Kind -eq 'proc') {
                        $message = Invoke-SurfAttach $e.Proc.Job
                        try {
                            $entries = Get-SurfListing $path
                            $cursor = [Math]::Min($cursor, $entries.Count - 1)
                        } catch { }
                        $lastW = -1   # attach owned the screen: force a full repaint
                    }
                    elseif ($e.Kind -eq 'blfolder') {
                        $blScope = $e.FullPath
                        $entries = Get-SurfBlacklistEntries $blScope
                        $mode = 'blacklist'
                        $cursor = 0; $scroll = 0
                    }
                    elseif ($e.Kind -eq 'bl' -and -not (Test-Path -LiteralPath $e.FullPath -PathType Container)) {
                        $message = 'Not a folder - un-list with B'
                    }
                    else {
                        if (Test-SurfProcsRunning) {
                            $confirmQuit = @{ Action = 'cd'; Target = $e.FullPath }
                        } else {
                            Set-Location -LiteralPath $e.FullPath; return
                        }
                    }
                }

                'Delete' {
                    $e = $entries[$cursor]
                    if (($mode -eq 'browse' -or $mode -eq 'results') -and ($e.Kind -eq 'dir' -or $e.Kind -eq 'file')) {
                        $confirmDelete = $e
                    } else {
                        $message = 'Only folders and files can be deleted'
                    }
                }

                'Spacebar' {
                    $e = $entries[$cursor]
                    if ($e.Kind -eq 'dir' -or $e.Kind -eq 'file' -or $e.Kind -eq 'mark') {
                        if ($marks -contains $e.FullPath) {
                            $marks = @($marks | Where-Object { $_ -ne $e.FullPath })
                            $message = "Un-marked: $($e.Name)"
                        } else {
                            $marks = @($marks) + $e.FullPath
                            $message = "Marked: $($e.Name)"
                        }
                        if ($mode -eq 'browse') {
                            try {
                                $entries = Get-SurfListing $path
                                $cursor = [Math]::Min($cursor, $entries.Count - 1)
                                for ($j = 0; $j -lt $entries.Count; $j++) {
                                    if ($entries[$j].FullPath -eq $e.FullPath) { $cursor = $j; break }
                                }
                            } catch { }
                        }
                    } else {
                        $message = 'Only folders and files can be marked'
                    }
                }

                'Escape' {
                    # priority: clear marks -> back out of views -> arm quit confirm -> quit
                    if ($marks.Count -gt 0) {
                        $marks = @()
                        if ($mode -eq 'browse') {
                            try { $entries = Get-SurfListing $path; $cursor = [Math]::Min($cursor, $entries.Count - 1) } catch { }
                        }
                        $message = 'Marks cleared'
                    } elseif ($mode -eq 'results' -or ($mode -eq 'blacklist' -and $blScope)) {
                        try { $entries = Get-SurfListing $path } catch { }
                        $mode = 'browse'; $blScope = $null; $cursor = 0; $scroll = 0
                    } elseif (Test-SurfProcsRunning) {
                        $confirmQuit = @{ Action = 'quit' }
                    } else { return }
                }
                default {
                    # letters were consumed by the dispatcher above; only symbols land here
                    $ch = $k.KeyChar
                    if ($ch -eq '/') {
                        $jumpPending = $true
                        $message = 'Jump to: press a letter'
                    } elseif ($ch -eq '?') {
                        if ($mode -eq 'browse' -or $mode -eq 'results') {
                            $helpPrev = @{ Mode = $mode; Entries = $entries; Cursor = $cursor; Scroll = $scroll }
                            $entries = Get-SurfHelpEntries
                            $mode = 'help'; $cursor = 0; $scroll = 0
                        }
                    }
                }
            }
        }
    } finally {
        # unconditional: deliberate exits were confirmed upstream, and an abnormal
        # unwind must never leave orphaned children (each job's kill-on-close handle
        # backs this up even if these calls fail)
        foreach ($pe in $procTable.ToArray()) {
            try { $pe.Job.KillTree() } catch { }
            try { $pe.Job.Dispose() } catch { }
        }
        $procTable.Clear()
        try { [Console]::CursorVisible = $cursorWasVisible } catch { }
        Clear-Host
    }

    # an exit-mode command runs here, after the TUI has fully released the console
    if ($pendingRun) {
        Set-Location -LiteralPath $pendingRun.Dir
        Write-Host "> $($pendingRun.Text)" -ForegroundColor DarkCyan
        $prevEnc = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            Invoke-Expression $pendingRun.Text
        } finally {
            try { [Console]::OutputEncoding = $prevEnc } catch { }
        }
    }
}

Export-ModuleMember -Function surf
