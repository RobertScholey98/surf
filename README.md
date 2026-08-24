# Surf

An interactive directory navigator for the Windows terminal. Browse folders with the
arrow keys, hit Enter to `cd` there. Favourites, a blacklist, recursive search, and
Windows Terminal tab integration included.

<!-- TODO: demo GIF here -->

## Install

From the [PowerShell Gallery](https://www.powershellgallery.com/):

```powershell
Install-Module Surf
```

Or straight from GitHub:

```powershell
irm https://raw.githubusercontent.com/RobertScholey98/surf/main/install.ps1 | iex
```

Or manually: download `Surf-<version>.zip` from the latest release and extract the
`Surf` folder into `Documents\WindowsPowerShell\Modules\` (PS 5.1) or
`Documents\PowerShell\Modules\` (PS 7).

Then just type `surf` — PowerShell auto-loads the module.

The installer offers to add `s` as a shorthand alias to your profile (pass `-Alias` or
`-NoAlias` when running it directly to skip the prompt). Gallery installs can add it
manually: `Set-Alias s surf` in your profile.

## Usage

```powershell
surf              # browse from the current directory
surf blacklist    # manage blacklisted folders and files
```

Every listing starts with a `.  (stay here)` entry — Enter on it drops you in the
folder you're viewing. Favourites are starred and float to the top. Directories
containing blacklisted items show a virtual `surf-blocklist (n folders, n files)`
entry at the bottom.

## Keys

| Key | Action |
| --- | --- |
| `Up` / `Down` | Move cursor |
| `Right` | Enter the highlighted folder (or drive) |
| `Left` | Go up one level (at a drive root: drive picker) |
| `Enter` | `cd` the terminal to the highlighted folder |
| `F` | Toggle favourite (starred, pinned to top) |
| `B` | Blacklist the highlighted item (hide from listings) |
| `T` | Open highlighted folder in a new Windows Terminal tab |
| `S` | Recursive folder search under the current directory |
| `Del` | Delete the highlighted item to the Recycle Bin (asks Y/N) |
| `Space` | Mark/un-mark the highlighted item (marks pin to the top and survive navigation) |
| `/` then a letter | Jump to the next folder starting with that letter |
| `a-z` `0-9` | Run the custom command bound to that key (chain prefixes open a menu) |
| `?` | Help overlay: every binding, built-in and custom |
| `Esc` / `Q` | Quit without changing directory (Esc clears marks first) |
| `Home` `End` `PgUp` `PgDn` | Larger cursor jumps |

## Custom commands

Bind your own keys to shell commands:

```powershell
surf add j "yarn dev"                       # prompts for description + run mode
surf add c "Copy-Item {selected} -Destination {dir}" -Contained
surf add d "yarn dev" -Background           # runs while you browse, pinned on top
surf add cc "claude" -Pane                  # opens in a Windows Terminal split
surf remove j
surf help                                   # every binding, built-in and custom
```

Run modes:

- **exit** — closes surf, cds to the folder you were viewing, runs the command in
  your terminal.
- **contained** — runs inside surf, shows the output, returns you to browsing
  (right for `git status`).
- **background** — the command keeps running while you browse. It pins to the top
  of every listing with its state and latest output line, live. **Enter** attaches:
  a real-time tail where typing sends input to the process (prompts work),
  **Ctrl+C** stops the whole process tree, **Esc Esc** detaches leaving it running,
  and **PgUp/PgDn** scroll its history. **K** kills (or dismisses an exited entry)
  without attaching.
- **pane** — opens the command in a Windows Terminal split beside surf. This is the
  home for full-screen TUIs (Claude Code, vim): they need a real terminal, which a
  captured background process is not.

Background processes are scoped to the surf session — one cockpit per terminal tab.
Leaving surf (cd, quit, or an exit-mode command) stops them, always behind a Y/N
confirm, and a kernel job object guarantees no orphaned processes even if the
terminal tab is closed mid-run.

The cockpit workflow this enables:

```powershell
surf add d "yarn dev" -Background
surf add w "yarn test --watch" -Background
surf add cc "claude" -Pane
```

One surf session, dev server and test watcher pinned live at the top, Claude in a
split beside it.

Templates: `{hovered}` is the item under the cursor, `{selected}` is everything
marked with Space, `{dir}` is the folder being viewed. Expansions are quoted
automatically; `{selected}` refuses to run when nothing is marked. Mark files in one
folder, navigate to another, and press your copy key — that's the workflow.

**Chains**: multi-character keys group commands under a prefix —

```powershell
surf add gs "git status" -Contained
surf add gp "git push" -Contained
```

Pressing `g` inside surf opens a which-key menu showing every `g…` completion with
its description; the next key runs it, Esc cancels. A key can never be both a
command and a prefix — `surf add` refuses conflicts with a list of what's in the way.

**Rebinding built-ins**: adding a command on a built-in key (say `b`) warns and
offers to move the built-in to a new key first, so your muscle memory wins without
losing the feature. Bindings live in `%APPDATA%\surf\keymap.json`; footers, `surf
help` and the `?` overlay all reflect your keymap.

In the blacklist view: `B` un-lists, `Enter` cds there, `Right` browses into it.
In search: type the query, `Enter` runs it (first 200 matches), `Esc` cancels;
in the results `Left`/`Esc` return to browsing.

## Where things live

State is stored in `%APPDATA%\surf\`:

- `blacklist.txt` — one full path per line
- `favourites.txt` — one full path per line

Both are plain text; edit them by hand if you like.

## Requirements

- Windows
- Windows PowerShell 5.1 or PowerShell 7+
- `T` (new tab) prefers Windows Terminal (`wt.exe`); without it, a new PowerShell
  window is opened instead

## License

[MIT](LICENSE)
