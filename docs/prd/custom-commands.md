# PRD: Custom Commands, Chained Keys, Marks & Templating

**Status:** needs-triage
**Target version:** 0.2.0
**Date:** 2026-07-03

## Problem Statement

Surf gets me to the right directory fast, but the moment I arrive I always do the same
next thing: `yarn dev` in the frontend repo, `git status` wherever I land, copy a file
somewhere else. Today that means quitting surf and typing the command myself, every
time. Surf knows where I am and what I'm pointing at — it should be able to run my
commands for me, on my keys, against the files I've picked.

## Solution

Users define their own key-bound commands with `surf add`. A single key (`j`) fires
immediately; a multi-character key (`gs`) becomes a chain — pressing `g` inside surf
opens a which-key style menu of every `g…` completion instead of firing anything.
Commands either exit surf and run in the real terminal (long-running/interactive work)
or run contained with their output shown before returning to browsing — chosen per
command at add time.

Command strings support templating: `{hovered}` (the item under the cursor),
`{selected}` (items marked with Space), and `{dir}` (the directory being viewed).
Marked items pin to a visible "selected" group at the top of every listing, survive
navigation between folders, and are cleared with Esc — enabling mark-here, navigate,
paste-there workflows.

`surf help` (and `?` inside surf) lists every binding. Built-in keys can be overridden,
with a guided flow that relocates the built-in to a new key. The a–z type-ahead jump
moves to `/` so all letters are free for user commands.

## User Stories

1. As a surf user, I want to bind a key to a shell command with `surf add j "yarn dev"`, so that I can launch my dev server the moment I navigate to the project.
2. As a surf user, I want to be prompted for a description when adding a command, so that `surf help` reminds me what each key does.
3. As a surf user, I want to choose per command whether it exits surf or runs contained, so that `yarn dev` owns my terminal while `git status` returns me to browsing.
4. As a surf user, I want an interactive exit/contained selector during `surf add`, so that I don't need to memorise flags.
5. As a surf user, I want `--exit` and `--contained` flags on `surf add`, so that scripted or repeat additions skip the prompt.
6. As a surf user, I want an exit-mode command to cd my terminal to the viewed directory before running, so that the command executes exactly where I was browsing.
7. As a surf user, I want a contained command's output displayed until I press a key, so that I can read the result and continue browsing where I left off.
8. As a surf user, I want multi-character keys like `gs` to become chains automatically, so that I can group related commands under one prefix without extra syntax.
9. As a surf user, I want pressing a chain prefix (`g`) to show a menu of all completions with their descriptions, so that I can discover and confirm what's available before committing.
10. As a surf user, I want Esc to back out of a chain menu without running anything, so that a mistyped prefix costs nothing.
11. As a surf user, I want `surf add` to refuse a key that conflicts with an existing command or prefix, with an error listing the conflicts, so that every keypress stays unambiguous.
12. As a surf user, I want to override a built-in key with my own command after a warning, so that my muscle memory wins over surf's defaults.
13. As a surf user, I want the override flow to offer to move the built-in to a new key, so that I never permanently lose a feature by rebinding.
14. As a surf user, I want `surf remove <key>` to delete a command, so that my keymap stays clean as my workflow changes.
15. As a surf user, I want `surf help` to print built-ins and custom commands with keys, descriptions and modes, so that I have one place to see my whole keymap.
16. As a surf user, I want `?` inside surf to show the same help as an overlay, so that I can check a binding without quitting.
17. As a surf user, I want to mark files and folders with Space, so that I can operate on several items at once.
18. As a surf user, I want marked items pinned in a visible "selected" group at the top of the listing, so that I can always see what's marked.
19. As a surf user, I want marks to survive navigating between folders, so that I can mark files in one place and act on them in another.
20. As a surf user, I want to unmark an individual item by pressing Space on it again (including in the pinned group), so that I can correct a mis-mark without starting over.
21. As a surf user, I want Esc to clear all marks before it does anything else, so that abandoning a selection is one keystroke.
22. As a surf user, I want a footer indicator of how many items are marked, so that stale marks never surprise me.
23. As a surf user, I want `{selected}` in a command template to expand to all marked paths as a quoted, comma-joined PowerShell array literal (cmdlets bind it as one parameter; native exes receive separate arguments), so that multi-file commands just work. *(Amended during implementation: space-separation breaks cmdlet positional binding.)*
24. As a surf user, I want `{hovered}` to expand to the item under my cursor, so that single-target commands don't require marking.
25. As a surf user, I want `{dir}` to expand to the directory I'm viewing, so that commands can target my current location.
26. As a surf user, I want a command using `{selected}` to refuse to run with a footer error when nothing is marked, so that it never silently acts on the wrong thing.
27. As a surf user, I want all template expansions automatically quoted, so that paths with spaces never break my commands.
28. As a surf user, I want type-ahead jump on `/` followed by a character, so that jumping still works while letters serve my commands.
29. As a surf user, I want custom commands to work in search results as well as normal browsing, so that found items get the same powers.
30. As a surf user, I want my commands and keymap persisted in my user data folder, so that they survive module updates and reinstalls.
31. As a new user with no custom commands, I want surf to behave exactly as before (minus the letter jump), so that the feature costs nothing until I opt in.
32. As a module consumer, I want the store, template and dispatch logic covered by unit tests in CI, so that keymap regressions are caught before release.

## Implementation Decisions

- **Five-module decomposition.** Three deep modules extracted to module scope so they
  are testable in isolation: a **command store** (load/save/validate `commands.json`
  and `keymap.json`; owns chain inference, prefix-conflict refusal, reserved-key and
  rebind rules), a **template engine** (pure function: command string + context
  {marked paths, hovered path, viewed dir} → expanded string or a typed
  empty-selection error), and a **key dispatcher** (pure state machine: pressed key +
  pending-chain state + command table → verdict: run command / show menu with
  completions / pass through to built-ins / reset). Two shallow layers: **TUI
  integration** (marks rendering, pinned group, which-key overlay, `?` overlay, `/`
  jump, Esc priority, contained-output screen) and the **CLI surface**
  (`surf add|remove|help` parsing and prompts, delegating to the store).
- **Dispatcher verdict shape** (from the grill, more precise than prose):
  `(key, pendingChain, commands) → { Action: 'run'|'menu'|'passthrough'|'reset';
  Command?: entry; Completions?: entry[] }`. Built-ins are consulted only on
  `passthrough`, which keeps the existing switch statement intact beneath the new layer.
- **Storage:** two JSON files in the existing user data folder — `commands.json`
  (key, command string, description, mode) and `keymap.json` (built-in action → key
  overrides; absent file means all defaults). Both created lazily like the existing
  blacklist/favourites files.
- **Chains are inferred from key length**; no `--chain` flag exists.
- **Prefix conflicts are refused at add time** with an error listing the conflicting
  entries; a key can never be both a command and a prefix.
- **Built-in override flow:** adding onto a built-in key warns, then interactively
  offers to relocate the built-in to a new key (validated against the same conflict
  rules) or abort.
- **Execution modes:** exit mode quits the TUI, sets the session location to the
  viewed directory, and invokes the command in the user's session so interactive and
  long-running commands behave natively. Contained mode runs in the viewed directory,
  prints output, waits for a keypress, and re-renders the TUI.
- **Esc priority order:** clear marks → back out of chain menu/overlay → back out of
  results/scoped views → quit.
- **Marks** are a session-scoped set of full paths (files and folders), rendered as a
  pinned group above the listing plus a footer count. Space toggles membership from
  either location. Marks do not persist across surf invocations.
- **Placeholders are strict:** `{selected}` never falls back to the hovered item;
  empty selection is a refusal, not a guess.
- **Type-ahead jump moves from bare letters to `/` + character** in the same release,
  making the letter namespace unambiguous: a letter is a custom command or nothing.
- **Reserved and non-rebindable:** arrows, Enter, Esc, `/`, Space, `?` — the keys the
  TUI itself needs to remain operable.
- **Two-phase delivery, each independently shippable:** phase 1 is marks, templating,
  single-key commands, `surf add/remove/help` and the `/` jump; phase 2 is chains,
  which-key menus, built-in rebinding and the `?` overlay.
- **Version bump to 0.2.0** — the keymap change (letter jump → `/`) is a
  behaviour-visible change.

## Testing Decisions

- First unit tests in the project: **Pester**, run in the existing CI workflow on the
  Windows runner alongside the current lint and import checks.
- Good tests exercise **external behaviour through each module's public interface**,
  never internal representation: given this commands file and this keypress, the
  dispatcher returns this verdict — not "the hashtable has these keys".
- **Command store tests:** chain inference, prefix-conflict refusal (both directions:
  adding a prefix of an existing chain and a chain under an existing key),
  reserved-key refusal, rebind validation, round-trip persistence.
- **Template engine tests:** each placeholder expands correctly, paths are quoted,
  multiple marks join space-separated, empty `{selected}` yields the typed error,
  unknown placeholders are left intact (or error — decided at implementation),
  commands with no placeholders pass through untouched.
- **Key dispatcher tests:** single key runs, prefix opens menu with correct
  completions, non-command key passes through, invalid continuation resets, Esc
  cancels a pending chain.
- **Prior art:** none in-repo (these are the first tests); the CI import checks in the
  existing workflow are the pattern for wiring new checks into the pipeline.
- TUI integration and CLI prompts are **manually tested** — they are thin over the
  tested modules by design.

## Out of Scope

- Command arguments or parameters at invocation time (`j` always runs the same string).
- Editing a command in place — change is remove + re-add.
- An in-TUI command editor; `surf add/remove` are CLI-only.
- Additional placeholders (`{name}`, `{ext}`, environment variables) beyond
  `{selected}`, `{hovered}`, `{dir}`.
- Per-directory or per-project command sets; the keymap is global.
- Marks persisting across surf sessions.
- Cross-platform (Linux/macOS) behaviour; the module remains Windows-only.
- Import/export or sharing of command sets.

## Further Notes

- Estimated at 400–500 new lines against the current ~550-line module — the largest
  single feature since the initial build. The riskiest corner is contained-mode screen
  restoration after arbitrary command output; everything else is bookkeeping.
- The README keys table, module header comment, and `surf help` output must all be
  updated together — after this feature there are three sources of key documentation,
  and `surf help` should be treated as the canonical one.
- The which-key menu reuses the existing overlay/list rendering machinery; no new
  rendering primitives are expected.
