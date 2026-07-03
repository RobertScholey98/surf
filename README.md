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

Then just type `surf` — PowerShell auto-loads the module. Fans of brevity can add
`Set-Alias s surf` to their profile.

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
| `Esc` / `Q` | Quit without changing directory |
| `a-z` `0-9` | Jump to the next folder starting with that character |
| `Home` `End` `PgUp` `PgDn` | Larger cursor jumps |

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
