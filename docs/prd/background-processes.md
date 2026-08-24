# PRD: Background Processes, Attach Views & Panes

**Status:** needs-triage
**Target version:** 0.3.0
**Date:** 2026-07-03

## Problem Statement

My projects need several long-running processes at once — a dev server, a test
watcher, a Claude Code session. Today surf can run a command (contained blocks
browsing until it finishes; exit closes surf entirely), so anything long-lived forces
me out of surf or eats the session. I want one surf session to be my cockpit: yarn
dev, yarn test and Claude all running simultaneously, visible while I browse, with
the keyboard able to reach each one.

## Solution

Two new run modes join exit/contained:

- **background** — the command spawns as a captured child process and surf keeps
  browsing. Running processes appear as a pinned group at the top of every listing
  with their state and live last output line. Enter attaches: a full-screen live
  tail where typed keys forward to the child's stdin, Ctrl+C stops the process
  tree, PgUp/PgDn scroll history, and double-Esc detaches leaving it running.
- **pane** — for full-screen TUIs (Claude Code) that need a real terminal: the
  command opens in a Windows Terminal split pane beside surf, fully interactive,
  navigated with WT's own keys.

Background processes are scoped to the surf session: quitting surf stops them all
(after a Y/N confirm whenever any are running), a kernel job object guarantees the
whole child tree dies with the terminal, and nothing is ever orphaned.

## User Stories

1. As a surf user, I want a background run mode (`surf add d "yarn dev" -Background`), so that pressing one key starts my dev server without leaving the browser.
2. As a surf user, I want running processes pinned at the top of every listing with name, state and the latest output line, so that my cockpit is always in view wherever I browse.
3. As a surf user, I want to attach to a process with Enter and see its live output stream in real time, so that I can watch a build or test run as it happens.
4. As a surf user, I want my keystrokes while attached forwarded to the process's stdin, so that y/n prompts and line input work without leaving surf.
5. As a surf user, I want Ctrl+C while attached to stop the process and its whole child tree, so that stopping yarn dev works the way my fingers expect.
6. As a surf user, I want double-Esc to detach from an attached process and leave it running, so that I can check on a server and go back to browsing.
7. As a surf user, I want a single Esc while attached forwarded to the child, so that prompts that read Esc still work.
8. As a surf user, I want PgUp/PgDn/Home/End while attached to scroll the process's output history, so that I can read errors that scrolled past.
9. As a surf user, I want to kill a hovered process with K without attaching, so that cleanup is one keystroke.
10. As a surf user, I want colours preserved in process output, so that test results and build errors read the way the tool intended.
11. As a surf user, I want quitting surf with processes running to ask Y/N before stopping them, so that I never kill a dev server by accident.
12. As a surf user, I want every process and its descendants killed when its surf session ends — including when the terminal tab closes — so that no orphaned node.exe survives.
13. As a surf user, I want one surf session per terminal tab, each owning its own processes, so that I can run a cockpit per worktree.
14. As a surf user, I want a pane run mode (`surf add cc "claude" -Pane`) that opens the command in a Windows Terminal split beside surf, so that fully interactive TUIs get a real terminal.
15. As a surf user, I want pane mode to fall back to a new window when Windows Terminal is not available, so that the command still runs everywhere.
16. As a surf user, I want a process that exits on its own to show as exited (with its exit code) in the pinned group until dismissed, so that I notice a crashed watcher.
17. As a surf user, I want K on an exited process to dismiss it from the list, so that finished jobs don't clutter the cockpit.
18. As a surf user, I want background/pane commands to support the same {hovered}/{selected}/{dir} templating as other modes, so that all four modes are one mental model.
19. As a surf user, I want `surf add` to offer all four run modes interactively and via flags, so that creating commands stays one flow.
20. As a surf user, I want `surf help` and the `?` overlay to show each command's mode including background/pane, so that my keymap stays self-documenting.
21. As a module consumer, I want the process buffer, mode validation and preview logic covered by tests in CI, so that the concurrency-adjacent code cannot silently regress.

## Implementation Decisions

- **Native helper, not PowerShell threads.** A small C# class compiled at module load
  (`Add-Type`) owns everything concurrent: it starts the process with redirected
  stdio, subscribes `OutputDataReceived`/`ErrorDataReceived` handlers that append to
  a lock-protected ring buffer (bounded, ~5,000 lines), exposes snapshot/last-line/
  state reads, stdin writes, and kill-tree. PowerShell only ever polls it — no
  PS-side event handlers, runspaces or timers, because the PS engine cannot run
  callbacks while the TUI blocks on a key read.
- **Kernel job object for lifecycle.** The helper creates a Windows job object with
  kill-on-close; every spawned process is assigned to it. Closing the terminal tab
  (or PowerShell dying) tears down every child tree at the kernel level — the
  no-orphans guarantee does not depend on surf's cleanup code running.
- **Session scoping.** The process table lives in the surf invocation. Any path out
  of the TUI (Enter cd, quit, exit-mode command) stops all processes, preceded by a
  footer Y/N confirm when any are running. Contained commands do not end the session.
- **Attach loop.** A dedicated inner loop: polls `KeyAvailable`, renders newly
  arrived lines between polls, `TreatControlCAsInput` on so Ctrl+C arrives as a key
  (restored on detach). Reserved keys: Ctrl+C (kill tree), double-Esc within 400ms
  (detach), PgUp/PgDn/Home/End (scrollback). Everything else — including single Esc
  after the window — forwards to the child's stdin. Line-based input is echoed
  locally as typed.
- **Colour strategy.** `FORCE_COLOR=1` injected into child environments. The attach
  view writes raw lines so Windows Terminal renders the ANSI; virtual-terminal
  processing is enabled on the output handle (with graceful fallback to stripping
  escapes on legacy consoles). Pinned-group previews always strip ANSI.
- **Pinned group.** Process entries render like the marks/blocklist groups: state
  glyph, command key/name, state (running/exited code), last output line. Enter
  attaches; K kills (running) or dismisses (exited); other item keys are inert on
  process entries.
- **Pane mode** shells out to `wt -w 0 sp -d <dir> <command>`; without wt it falls
  back to `Start-Process powershell -WorkingDirectory`. Panes are fire-and-forget:
  surf does not track them (they are real terminals, not captured children).
- **Store.** `Mode` gains `background` and `pane` as valid values; `Add-SurfCommand`
  validates the mode set so a hand-edited commands.json cannot inject nonsense. The
  CLI selector becomes (e)xit / (c)ontained / (b)ackground / (p)ane with matching
  switches.
- **Templating** applies identically in all four modes, expanded at launch time.

## Testing Decisions

- Same Pester/CI arrangement as 0.2.0; tests exercise behaviour through public
  interfaces only.
- **Process buffer tests** (real child processes, e.g. `cmd /c echo`): output
  captured to the buffer, last-line correct, exit detected with code, ring buffer
  truncates at capacity, stdin write reaches the child, kill-tree terminates a
  process that spawned a child.
- **Store tests:** background/pane accepted as modes, invalid mode refused.
- **Preview logic tests:** ANSI escape stripping, last-line selection over empty
  output.
- The attach view, quit-confirm flow and pane launching are manual-test surfaces —
  thin layers over the tested helper by design.

## Out of Scope

- Hosting full-screen TUIs inside surf (requires ConPTY plus a VT emulator — a
  terminal-emulator project, deliberately excluded; pane mode is the answer).
- Processes surviving the surf session or the terminal.
- Managing/tracking Windows Terminal panes after launch.
- Restart-on-crash, log persistence to disk, or output search.
- Cross-platform behaviour; the helper is Windows-only by design.

## Further Notes

- Estimated 500–700 new lines plus the C# helper. The riskiest surfaces are the
  attach loop's reserved-key handling and the Ctrl+C ownership handover; both are
  isolated behind the helper's simple polling interface.
- The which-key and help surfaces must present four modes; README gains a cockpit
  section with the yarn dev / yarn test / claude example.
