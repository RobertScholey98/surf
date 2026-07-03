# Surf - an interactive directory navigator for the terminal.
#
# Usage:
#   surf              browse from the current directory
#   surf blacklist    manage blacklisted folders and files
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
#   Esc / Q          quit without changing directory
#   a-z / 0-9        jump to the next folder starting with that character (B, F, S, T and Q are reserved)
#   Home/End/PgUp/PgDn  larger cursor jumps
#
# Keys (blacklist view):
#   B                un-list the highlighted item
#   Enter            cd to the highlighted folder
#   Right            browse into the highlighted folder
#
# State lives in %APPDATA%\surf\ (blacklist.txt and favourites.txt, one full path per line).

$script:SurfDataDir        = Join-Path $env:APPDATA 'surf'
$script:SurfBlacklistFile  = Join-Path $script:SurfDataDir 'blacklist.txt'
$script:SurfFavouritesFile = Join-Path $script:SurfDataDir 'favourites.txt'

function surf {
    param([string]$Command)

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
        $blDirs = 0; $blFiles = 0
        $favD = @(); $normD = @(); $favF = @(); $normF = @()
        foreach ($d in @($items | Where-Object { $_.PSIsContainer } | Sort-Object Name)) {
            if ($blacklist -contains $d.FullName) { $blDirs++; continue }
            if ($favourites -contains $d.FullName) { $favD += ,(New-SurfEntry $d.Name 'dir' $d.FullName $true) }
            else { $normD += ,(New-SurfEntry $d.Name 'dir' $d.FullName) }
        }
        foreach ($f in @($items | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)) {
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

    if ($Command) {
        if ($Command -eq 'blacklist') {
            $mode = 'blacklist'
            $entries = Get-SurfBlacklistEntries
        } else {
            Write-Warning "surf: unknown command '$Command' (try: surf blacklist)"
            return
        }
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

        while ($true) {
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
                    $line = if ($e.Fav) { " * $label" } else { "   $label" }
                    # files carry their modified date, right-aligned at the screen edge
                    $date = if ($e.Kind -eq 'file' -and $e.Date) { $e.Date.ToString('g') } else { '' }
                    if ($i -eq $cursor) {
                        # arrow + enter-symbol hint on the hovered row; built from char codes
                        # because literal unicode garbles under PS 5.1's ANSI script parsing.
                        # Only shown where Enter actually does something (not files).
                        $hint = ''
                        $arrow = [char]0x2192; $ret = [char]0x21B5
                        if ($e.Kind -eq 'self') { $hint = "  $ret CD into" }
                        elseif ($e.Kind -eq 'blfolder') { $hint = "  $arrow $ret open" }
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
                    if ($e.Fav) {
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

            $footer = if ($confirmDelete) { " Delete '$($confirmDelete.Name)' (to Recycle Bin)?   Y / N" }
                      elseif ($mode -eq 'search-input') { " Search: $searchQuery" + '_   (Enter search, Esc cancel)' }
                      elseif ($message) { " $message" }
                      elseif ($mode -eq 'blacklist' -and $blScope) { ' Up/Dn   -> browse   <-/Esc back   Enter cd   B un-list   T tab   Q quit' }
                      elseif ($mode -eq 'blacklist') { ' Up/Dn   -> browse   Enter cd   B un-list   T tab   Esc/Q quit' }
                      elseif ($mode -eq 'results') { ' Up/Dn   -> browse   <-/Esc back   Enter cd   B blacklist   T tab   Q quit' }
                      else { ' Up/Dn   -> in   <- up   Enter cd   S search   F fav   B blacklist   T tab   Esc/Q quit' }
            if ($footer.Length -gt $w - 1) { $footer = $footer.Substring(0, $w - 1) }
            $footerColor = if ($confirmDelete) { 'Yellow' } else { 'DarkGray' }
            Write-Host ($footer.PadRight($w - 1)) -ForegroundColor $footerColor -NoNewline
            $message = ''

            # ---- input --------------------------------------------------
            $k = [Console]::ReadKey($true)

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
                    } elseif ($e.Kind -eq 'dir' -or $e.Kind -eq 'drive' -or $e.Kind -eq 'bl') {
                        try {
                            $entries = Get-SurfListing $e.FullPath
                            $path = $e.FullPath
                            $mode = 'browse'
                            $cursor = 0; $scroll = 0
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
                    elseif ($e.Kind -eq 'blfolder') {
                        $blScope = $e.FullPath
                        $entries = Get-SurfBlacklistEntries $blScope
                        $mode = 'blacklist'
                        $cursor = 0; $scroll = 0
                    }
                    elseif ($e.Kind -eq 'bl' -and -not (Test-Path -LiteralPath $e.FullPath -PathType Container)) {
                        $message = 'Not a folder - un-list with B'
                    }
                    else { Set-Location -LiteralPath $e.FullPath; return }
                }

                'B' {
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

                'T' {
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

                'F' {
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

                'S' {
                    if ($mode -eq 'browse' -or $mode -eq 'results') {
                        $searchPrev = @{ Mode = $mode; Entries = $entries; Cursor = $cursor; Scroll = $scroll }
                        $mode = 'search-input'
                        $searchQuery = ''
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

                'Escape' {
                    if ($mode -eq 'results' -or ($mode -eq 'blacklist' -and $blScope)) {
                        try { $entries = Get-SurfListing $path } catch { }
                        $mode = 'browse'; $blScope = $null; $cursor = 0; $scroll = 0
                    } else { return }
                }
                'Q'      { return }

                default {
                    # type-ahead: jump to the next folder starting with the typed character
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
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $cursorWasVisible } catch { }
        Clear-Host
    }
}

Export-ModuleMember -Function surf
