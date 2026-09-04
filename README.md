# Surf

[![CI](https://github.com/RobertScholey98/surf/actions/workflows/ci.yml/badge.svg)](https://github.com/RobertScholey98/surf/actions/workflows/ci.yml)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/Surf.svg?label=PSGallery)](https://www.powershellgallery.com/packages/Surf)
[![PowerShell Gallery downloads](https://img.shields.io/powershellgallery/dt/Surf.svg?label=downloads)](https://www.powershellgallery.com/packages/Surf)
[![GitHub release](https://img.shields.io/github/v/release/RobertScholey98/surf)](https://github.com/RobertScholey98/surf/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**A keyboard-first directory navigator and Git worktree manager for Windows terminals.**

Surf replaces the repetitive `ls`, `cd`, and `git worktree` commands in a normal
terminal workflow. Browse with the arrow keys, press Enter to move the calling shell,
and manage every worktree in the repository without remembering Git's worktree syntax.

[Installation](#installation) · [Updating](#updating) · [Quick start](#quick-start) · [Key reference](#key-reference) · [Git worktrees](#git-worktrees) · [Custom commands](#custom-commands)

## Why Surf?

- **Navigate without typing paths.** Browse folders and drives interactively, including
  hidden items, favourites, recursive search, and a persistent blocklist.
- **Keep worktrees under control.** Create, inspect, enter, and remove worktrees from a
  dedicated keyboard-driven view.
- **Bring common commands with you.** Bind commands to single keys or discoverable key
  chains, with the hovered item, marked items, and current directory as inputs.
- **Stay inside the terminal.** Run quick commands inline, keep long-running processes
  attached to the Surf session, or open a full TUI in a Windows Terminal pane.
- **Use Windows-native safety rails.** File deletion goes to the Recycle Bin, destructive
  worktree operations are confirmed, and background process trees are cleaned up when
  the Surf session ends.

## Installation

### PowerShell 7.4 or newer (recommended)

Surf is published on the [PowerShell Gallery](https://www.powershellgallery.com/packages/Surf):

```powershell
Install-PSResource Surf -Scope CurrentUser -TrustRepository
```

PowerShell 7.4 and newer include `Microsoft.PowerShell.PSResourceGet`, the package manager
used by Surf's built-in updater. PowerShell auto-loads the module the first time you run
`surf`; no profile import is required.

### Windows PowerShell 5.1 or older PowerShell 7 releases

Surf also supports Windows PowerShell 5.1 and earlier PowerShell 7 releases:

```powershell
Install-Module Surf -Scope CurrentUser
```

The `surf update` command requires `Microsoft.PowerShell.PSResourceGet`. Follow Microsoft's
[package-manager installation guide](https://learn.microsoft.com/powershell/gallery/powershellget/install-powershellget)
to add it on versions of PowerShell that do not include it.

### Install from GitHub instead

```powershell
irm https://raw.githubusercontent.com/RobertScholey98/surf/main/install.ps1 | iex
```

The installer downloads the latest GitHub release and places Surf in the current user's
module directory. Run the same command again to update an existing installation.

When run interactively, the installer can also add `s` as an alias for `surf` to your
PowerShell profile. Use `-Alias` or `-NoAlias` when running a local copy of the script to
skip that prompt.

### Manual installation

Download `Surf-<version>.zip` from the latest
[GitHub release](https://github.com/RobertScholey98/surf/releases/latest), then extract
the included `Surf` folder into the appropriate module directory:

- Windows PowerShell 5.1: `Documents\WindowsPowerShell\Modules\`
- PowerShell 7+: `Documents\PowerShell\Modules\`

### Optional shorthand

Add this to your PowerShell profile if you prefer to launch Surf with `s`:

```powershell
Set-Alias -Name s -Value surf
```

## Updating

From version 0.5.3 onward, update the CurrentUser Gallery installation with:

```powershell
surf update
```

Surf compares the installed version with the latest stable Gallery release. It installs
Surf if only a development checkout exists, updates an older installation, and does
nothing when the installed version is already current. The repository checkout is never
modified.

Open a new PowerShell session after an update. PowerShell does not replace a module—or
Surf's compiled process helper—while the current session is still using it.

## Quick start

Launch Surf from any directory:

```powershell
surf
```

Surf opens a full-screen listing at the shell's current location. Navigation inside
Surf does not change the calling shell immediately:

1. Use **Up** and **Down** to select an entry.
2. Use **Right** to browse into a folder and **Left** to browse back up.
3. Press **Enter** when you have reached the directory you want.
4. Surf closes and moves the calling PowerShell session to that directory.

Every listing begins with `.  (stay here)`. Pressing Enter on it selects the directory
currently being viewed, which is useful after browsing around without highlighting a
child folder.

Other command-line entry points:

```powershell
surf blacklist                         # manage blocked paths
surf help                              # print built-in and custom bindings
surf -v                                # print the loaded Surf version
surf update                            # update the Gallery installation
surf add gs "git status" -Contained    # add a custom command
surf remove gs                         # remove a custom command
```

## Key reference

The letters below are the defaults. Built-in letter bindings can be relocated when a
custom command needs the same key, and Surf's help screens always show the active
keymap.

### Navigation

| Key | Action |
| --- | --- |
| `Up` / `Down` | Move the cursor one row |
| `Right` | Browse into the highlighted folder, drive, or worktree |
| `Left` | Go to the parent folder; from a drive root, open the drive picker |
| `Enter` | Select the highlighted directory, close Surf, and move the calling shell there |
| `Home` / `End` | Jump to the first or last row |
| `PgUp` / `PgDn` | Move by one visible page |
| `/`, then a letter | Jump to the next folder beginning with that letter |
| `Space` | Mark or unmark the highlighted file or folder |
| `Esc` | Clear marks first, then leave the current view or quit |
| `Q` | Quit without changing directory |

### Actions and views

| Key | Action |
| --- | --- |
| `F` | Toggle the highlighted file or folder as a favourite |
| `B` | Add the highlighted item to the blocklist; inside the blocklist view, restore it |
| `S` | Search recursively for folders below the current directory |
| `T` | Open the highlighted directory in a new Windows Terminal tab |
| `W` | Open the Git worktree management view |
| `Del` | Move the highlighted file or folder to the Recycle Bin after confirmation |
| `?` | Open the in-app help overlay |
| `a-z`, `0-9` | Run a custom command or open a custom command chain |

## Everyday navigation features

### Favourites

Press `F` on a file or folder to toggle it as a favourite. Favourites are highlighted
and float to the top of the listing, with folders before files. They persist between
Surf sessions.

### Marks

Press `Space` to mark files and folders. Marks remain visible at the top of each listing
and survive navigation, making it possible to select items in one directory and use
them in a command somewhere else. Press `Esc` to clear the complete marked set.

Marks are session-scoped and are primarily intended for the `{selected}` custom-command
placeholder.

### Search

Press `S`, type part of a folder name, and press Enter. Surf searches recursively below
the current directory and displays the first 200 matching folders. Blocked directories
and their descendants are excluded.

Use `Left` or `Esc` to return to normal browsing. Search results support the same Enter,
Right, favourite, blocklist, terminal-tab, and custom-command actions as ordinary
directory rows.

### Blocklist

Press `B` to hide an item from Surf. A directory containing hidden direct children gets
a virtual `surf-blocklist` row showing how many folders and files are blocked there.

Manage the complete blocklist with:

```powershell
surf blacklist
```

Inside that view, `B` restores an item, Enter selects a directory, and Right browses
into it. Blocking only affects Surf's listings; it never modifies the underlying item.

## Git worktrees

Press `W` anywhere inside a Git repository to open its worktree management view. Surf
reads Git's own worktree registry, so worktrees created by other tools appear
automatically.

Each row shows the checkout folder, branch, and useful context:

- `(main)` identifies the primary worktree.
- `(here)` identifies the worktree containing the directory Surf is browsing.
- `N changed` counts uncommitted entries.
- `N unpushed` counts commits reachable from `HEAD` but from no remote ref.
- `N behind` compares the worktree with the default branch as last fetched.

Blank status space means the worktree is clean and has no unpushed or behind commits.

| Key | Worktree action |
| --- | --- |
| `Enter` | Leave the management view and browse into the selected worktree |
| `N` | Create a local branch and worktree |
| `R` | Check out an `origin` branch or open pull request into a new worktree |
| `D` | Remove the selected worktree and delete its local branch |
| `Esc` / `W` | Return to the previous Surf view |

### Create a local worktree

Press `N` and complete three prompts:

1. **Branch name** — the new local branch to create.
2. **Base ref** — a branch, remote ref, or commit. Press Enter for the latest known
   default branch; Surf fetches `origin` first when one is configured.
3. **Path** — interpreted relative to the repository root and pre-filled from the branch
   name.

The new branch is created without an upstream. Publishing and choosing its upstream
remain explicit `git push` decisions.

### Check out a remote branch or pull request

Press `R` to open the remote picker:

- With the [GitHub CLI](https://cli.github.com/) installed and authenticated, Surf lists
  open pull requests by number, title, and branch.
- Otherwise, Surf lists the branches available from `origin`.

After a branch is selected, choose the worktree path. Surf fetches the branch, creates a
local branch with the same name, and configures it to track `origin/<branch>`.

### Git and GitHub authentication

Surf does not store credentials or implement a separate GitHub login. It delegates to
the tools already configured on the machine:

- Local worktree listing, creation, status, navigation, and removal use `git` and do not
  require a network connection.
- Fetching and remote-branch discovery use the repository's `origin` remote. HTTPS
  credentials come from Git Credential Manager; SSH remotes use the user's SSH setup.
- The remote picker uses `gh pr list` when GitHub CLI is installed and authenticated. If
  that query is unavailable, Surf falls back to branches returned by `git ls-remote`.
- Public repositories can normally fetch without authentication. Private repositories
  require working Git credentials for remote operations.

Surf disables interactive Git credential prompts while its full-screen UI is active, so
an unauthenticated or unreachable remote fails instead of leaving Surf hanging. Local
operations remain available, and local worktree creation can fall back to cached remote
refs or a local `main`/`master` branch. Surf never pushes a branch; authentication for a
later `git push` happens normally in the user's terminal.

> **Current limitation:** the selected branch must be fetchable from `origin`. Pull
> requests whose head branch exists only in a contributor's fork are displayed by the
> GitHub CLI picker but cannot currently be checked out by Surf.

### Remove a worktree

Press `D` and confirm the named worktree and branch. Surf removes the worktree and then
force-deletes its local branch. If the worktree contains uncommitted changes, Surf asks
for a second explicit confirmation before using Git's forced removal.

The main worktree is never removable. When removing the worktree containing the current
shell location, Surf first relocates the shell and browser to the main worktree.

Opening the management view also runs `git worktree prune`, clearing stale worktree
registrations before the list is shown.

## Custom commands

Custom commands turn frequently repeated shell commands into single keys or key chains:

```powershell
surf add j  "yarn dev"
surf add gs "git status" -Contained
surf add cp "Copy-Item {selected} -Destination {dir}" -Contained
surf add d  "yarn dev" -Background
surf add cc "claude" -Pane
```

Without a mode switch, `surf add` asks for a description and run mode. Descriptions are
shown by `surf help`, the `?` overlay, and chain menus.

### Run modes

| Mode | Switch | Behavior |
| --- | --- | --- |
| Exit | `-Exit` | Close Surf, move to the viewed directory, and run in the calling shell |
| Contained | `-Contained` | Run inside Surf, keep the output visible, then return to browsing |
| Background | `-Background` | Keep running while Surf remains open and pin live status above the listing |
| Pane | `-Pane` | Open in a Windows Terminal split; fall back to a new PowerShell window |

### Placeholders

| Placeholder | Expands to |
| --- | --- |
| `{hovered}` | Full path of the row under the cursor |
| `{selected}` | All paths marked with Space |
| `{dir}` | Directory currently being viewed |

Path expansions are quoted automatically. A command using `{selected}` refuses to run
when nothing is marked, rather than guessing at a target. After a successful command
consumes `{selected}`, Surf clears the marked set.

### Key chains and built-in rebinding

Multi-character bindings form discoverable chains automatically:

```powershell
surf add yb "yarn build" -Contained
surf add yd "yarn dev" -Contained
surf add yi "yarn install" -Contained
```

Pressing `Y` opens a which-key menu showing the allowable next keys and their commands:

```text
[y] which key next?
  b   yarn build
  d   yarn dev
  i   yarn install
```

Continue the chain to run one or press Esc to cancel. Longer chains narrow the menu after
each prefix. A binding cannot be both a complete command and a prefix, so Surf rejects
ambiguous combinations when they are added.

If a custom command starts with a built-in key, Surf offers to move that built-in to a
different free key first. Help text and footers use the resulting keymap automatically.

## Background processes and panes

Background commands are owned by the current Surf session. Each appears above the
directory listing with its state and latest output line.

| Key | Background-process action |
| --- | --- |
| `Enter` | Attach to the highlighted process and follow its output |
| `K` | Stop a running process tree or dismiss an exited process |
| `Ctrl+C` | Stop the complete process tree while attached |
| `Esc Esc` | Detach while leaving the process running |
| `PgUp` / `PgDn` / `Home` / `End` | Browse captured output history |

Surf captures complete lines and unterminated prompts, forwards line input to the child,
and keeps a bounded in-memory history. Exiting Surf with active processes requires
confirmation. A Windows job object ensures child processes are cleaned up with their
owning Surf session, including when the terminal tab closes unexpectedly.

Pane mode is intended for full-screen interactive applications such as editors and AI
coding tools. These receive a real terminal rather than captured standard streams.

## Configuration and stored data

Surf stores per-user state in `%APPDATA%\surf\`:

| File | Purpose |
| --- | --- |
| `blacklist.txt` | Blocked paths, one full path per line |
| `favourites.txt` | Favourite paths, one full path per line |
| `commands.json` | Custom commands, descriptions, keys, and run modes |
| `keymap.json` | Active built-in key bindings |

No repository-local Surf configuration is required. Marks and background processes exist
only for the lifetime of the current Surf session.

## Requirements

- Windows
- PowerShell 7.4 or newer recommended
- Windows PowerShell 5.1 and older PowerShell 7 releases supported
- `Microsoft.PowerShell.PSResourceGet` for `surf update` (included with PowerShell 7.4+)
- Git for worktree functionality
- Optional: [Windows Terminal](https://github.com/microsoft/terminal) for tabs and panes
- Optional: [GitHub CLI](https://cli.github.com/) for the pull-request picker

Without Windows Terminal, tab and pane actions fall back to a new PowerShell window.
Without Git or outside a repository, ordinary directory navigation remains available.

## Troubleshooting

### `surf` is not recognized

Check that the module is installed and visible to the current PowerShell edition:

```powershell
Get-Module -ListAvailable Surf
Get-Command surf
```

Windows PowerShell 5.1 and PowerShell 7 use different default user module directories.
Install Surf from the edition in which you intend to run it.

### The worktree view does not open

Run `git status` from the same directory. Surf enables worktree controls only when it can
find a `.git` directory or linked-worktree `.git` file in the current path or an ancestor.

### Pull requests are not listed

Confirm that `gh` is available and authenticated:

```powershell
gh auth status
```

If the GitHub CLI is unavailable or its query fails, Surf falls back to branches from
`origin`. Check Git's access to that remote separately with:

```powershell
git ls-remote --heads origin
```

This distinction matters for private repositories: `gh auth status` verifies GitHub CLI,
while the repository remote may use separate Git Credential Manager or SSH credentials.

## Development

### Use the release while developing locally

Keep the Gallery installation as the daily driver and import the repository copy only in
a dedicated development shell. A normal terminal auto-loads the Gallery version when
`surf` is first called. From the repository, start a separate shell and import the source
manifest explicitly:

```powershell
pwsh -NoProfile
Import-Module .\Surf\Surf.psd1 -Force -ErrorAction Stop
(Get-Module Surf).Path
```

Re-run `Import-Module` after editing `Surf.psm1`. Start a fresh development shell after
editing `SurfJob.cs`, because .NET cannot replace its already-loaded type. Closing the
development shell returns normal terminals to the Gallery installation. Both copies use
the same user settings under `%APPDATA%\surf`.

`surf update` always targets the CurrentUser Gallery installation. It never changes files
inside the repository, even when invoked from an explicitly imported development copy.

### Repository structure

Repository layout:

| Path | Purpose |
| --- | --- |
| `Surf/Surf.psm1` | PowerShell module, state management, Git integration, and TUI |
| `Surf/SurfJob.cs` | Background process, bounded output buffer, and Windows job object |
| `Surf/Surf.psd1` | Module manifest and release metadata |
| `tests/` | Pester behavior and compatibility tests |
| `docs/prd/` | Product and implementation decisions for major features |

Useful local checks:

```powershell
Import-Module .\Surf\Surf.psd1 -Force -ErrorAction Stop
Invoke-Pester -Path .\tests
Invoke-ScriptAnalyzer -Path .\Surf -Recurse -Severity Warning,Error
.\build.ps1
```

The build script creates `dist\Surf-<version>.zip`, matching the layout expected by the
installer and GitHub release workflow.

Design documents:

- [Custom commands](docs/prd/custom-commands.md)
- [Background processes](docs/prd/background-processes.md)
- [Git worktree operations](docs/prd/worktree-operations.md)

## License

Surf is available under the [MIT License](LICENSE).
