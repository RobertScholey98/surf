# PRD: Git Worktree Operations

**Status:** needs-triage
**Target version:** 0.4.0
**Date:** 2026-08-24

## Problem Statement

I work in repos with multiple git worktrees, but I can never remember the worktree
commands. Creating one means recalling `git worktree add` syntax, deciding a path,
fetching the right base, and typing branch plumbing by hand. Removing a finished one is
worse — the worktree, its folder, and its branch all need cleaning up separately, and
half the time a stale entry or an orphaned branch lingers. Reviewing someone else's PR
means manually fetching their branch and checking it out somewhere without disturbing my
own work. Surf already knows where I am; it should handle the worktree ceremony for me.

## Solution

Inside any git repo, pressing `w` in surf opens a full-screen worktree management area
for that repo: every worktree listed (main first), the one I'm standing in pre-selected.
From there, Enter browses into a worktree, `n` creates a new local branch + worktree,
`r` checks out a remote branch (someone's PR) into a new worktree, and `d` removes the
selected worktree *and* its local branch in one confirmed step — warning me only if
there are uncommitted changes. Stale worktree entries are pruned automatically whenever
the list is built, so ghosts never accumulate.

While browsing normally, worktrees appear visually grouped under a small subheading in
the listing — glanceable "which worktrees exist, which am I in" — but all mutation lives
in the management area. Both add flows ask one path question (pre-filled with the branch
name, relative to the repo root) and leave me exactly where I was; the new worktree
simply appears in the lists. The local flow's base-ref prompt defaults to the *latest*
default branch (fetch first, `origin/HEAD`); the remote flow lists open PRs via the
GitHub CLI when it's available, falling back to plain remote branches when it isn't.

## User Stories

1. As a surf user, I want to press `w` anywhere inside a git repo to open a worktree management area, so that all worktree operations live in one place I can actually remember.
2. As a surf user, I want the management area to list every worktree with its branch and repo-root-relative path, main worktree first, so that I can see the whole picture at a glance.
3. As a surf user, I want the worktree I'm currently standing in pre-selected when the management area opens, so that "remove the one I'm done with" is two keypresses.
4. As a surf user, I want Enter on a worktree row to leave the management area and browse into that worktree, so that jumping between worktrees feels like normal surf navigation.
5. As a surf user, I want `Esc`, `q`, or `w` to close the management area back to browsing, so that peeking at the list costs nothing.
6. As a surf user, I want `n` to create a new local branch and worktree, so that starting parallel work doesn't require remembering `git worktree add` syntax.
7. As a surf user, I want the local flow to prompt me for a branch name, so that the branch is named what I want from the start.
8. As a surf user, I want the local flow to prompt for a base ref where plain Enter means the *latest* default branch (fetched first), so that new work starts from up-to-date master without me typing anything.
9. As a surf user, I want to type any ref (remote branch, local branch, SHA) as the base, so that exotic bases are possible without leaving surf.
10. As a surf user, I want the new local branch created with no upstream, so that nothing is pushed or tracked until I decide to publish it.
11. As a surf user, I want `r` to check out a remote branch into a new local worktree, so that I can look at someone else's PR without disturbing my own checkouts.
12. As a surf user, I want the remote flow to list open PRs as `#123 title [branch]` (drafts included, newest first) when the GitHub CLI is available, so that I pick by PR, not by guessing branch names.
13. As a surf user, I want the remote flow to fall back to listing all remote branches when the GitHub CLI is missing or fails, so that the feature still works on machines without `gh`.
14. As a surf user, I want the remote checkout to create a local branch named after the remote branch, tracking it, so that pulling the PR author's updates is a plain `git pull`.
15. As a surf user, I want both add flows to ask one path question, pre-filled with the branch name and interpreted relative to the repo root, so that Enter gives a sane default and typing a relative path steers it anywhere.
16. As a surf user, I want to stay exactly where I was after adding a worktree, so that creating one doesn't yank me out of what I was doing.
17. As a surf user, I want a newly added worktree to appear immediately in the management list and the browse grouping, so that I can see the operation worked.
18. As a surf user, I want `d` to remove the selected worktree and force-delete its local branch in one step, so that finishing a piece of work is one confirmed action instead of three commands.
19. As a surf user, I want the removal confirm to name exactly which worktree and branch are about to be deleted, so that I never delete the wrong one.
20. As a surf user, I want an explicit second warning when the worktree being removed has uncommitted changes, so that unsaved work never vanishes silently.
21. As a surf user, I want no unmerged-branch nag beyond that, so that abandoning an experiment is frictionless — the branch is released-or-abandoned by definition.
22. As a surf user, I want the main worktree to be unremovable from surf, so that I can't destroy the primary checkout by muscle memory.
23. As a surf user, I want to be returned to the main worktree when I remove the worktree I'm standing in, so that "I'm done here" lands me somewhere valid.
24. As a surf user, I want `git worktree prune` to run silently whenever the list is built, so that manually deleted folders never show as ghost rows.
25. As a surf user, I want worktrees grouped under a small subheading with an indicator in every browse listing inside the repo, so that I always know which worktrees exist and which one I'm in.
26. As a surf user, I want the browse grouping to be visual/navigational only, so that destructive actions can't happen outside the management area.
27. As a surf user, I want pressing `w` outside a git repo to show a footer notice and do nothing else, so that the key is safe to mash.
28. As a surf user, I want `w` to be a rebindable built-in that my custom commands can override, so that it obeys the same keymap rules as every other built-in.
29. As a surf user, I want the `w` binding and management-area keys listed in the help overlay, so that I never have to remember them cold.
30. As a surf user, I want a clear footer error when an add fails (branch exists, path occupied, branch already checked out elsewhere, fetch failure), so that I know what to fix without reading git stderr archaeology.
31. As a surf user, I want a "fetching…" style footer note during network operations, so that a slow remote doesn't look like a hang.
32. As a surf user on Windows PowerShell 5.1, I want all of this to work identically to PS7, so that the module keeps its single-codebase guarantee.

## Implementation Decisions

- **Repo detection**: any directory inside a git repo (resolved via git plumbing, e.g. `rev-parse --git-common-dir`) has worktree features; no config, no opt-in. Outside a repo `w` shows a footer notice.
- **Six-module split**, following the module's established pure-core / thin-TUI pattern:
  - *Git runner* — one choke-point function that shells out to git in a given directory and returns `@{Ok; Output; Error}`; every other module calls git through it so tests can mock a single seam.
  - *Repo/worktree model* — repo detection plus a pure parser turning `git worktree list --porcelain` text into entries (`Path`, `Branch`, `IsMain`, `IsCurrent`).
  - *Branch-source parsers* — pure functions converting `gh pr list` JSON and `git ls-remote --heads` text into one uniform picker-entry shape (`Display`, `Branch`); provider selection (gh vs fallback) is a thin wrapper around them.
  - *Operation planners* — pure decision logic producing validated git argument sequences or precise errors: an add planner (branch name + base + repo-root-relative path → steps) and a remove planner (entry + dirty flag → ordered steps + required confirms; refuses the main worktree). Every safety rule in this PRD lives here, not in the TUI.
  - *Worktree management TUI mode* — a new mode in the render/input loop: list render, `n`/`r`/`d`/Enter/Esc keys, text-input substates reusing the existing search-input pattern, confirms reusing the existing footer Y/N pattern.
  - *Browse integration* — worktree subheading group in the listing builder (new entry Kind, one cached porcelain call per directory load), the `w` keymap entry, help overlay entries.
- **Local add sequence**: fetch origin (skipped when no remote, with local `main`/`master` fallback) → resolve default base from `origin/HEAD` → create branch from chosen base with no upstream → `git worktree add` at the chosen path.
- **Remote add sequence**: pick branch (gh PR list or ls-remote fallback) → fetch that branch → `git worktree add` with a local branch named after the remote branch, tracking it.
- **Path prompt**: single text input, pre-filled with the branch name, interpreted relative to the repo root; blank/Enter accepts the default.
- **Remove sequence**: confirm (naming worktree + branch) → dirty check → optional force confirm → `git worktree remove` (force when confirmed) → `git branch -D`. Removing the current worktree relocates surf to the main worktree first.
- **Prune**: `git worktree prune` runs silently every time the worktree list is built.
- **Keymap**: `w` joins the built-in keymap (rebindable, overridable by custom commands, subject to the existing conflict rules). Keys inside the management mode are fixed, not keymap entries — consistent with other modes.
- **Rendering constraint**: PS 5.1-safe throughout — no literal non-ASCII in source (char-code composition, as existing code does), no generic-List pitfalls, `Write-Host` rendering consistent with existing modes.
- **Perf constraint**: browse integration adds at most one `git worktree list --porcelain` call per directory load, cached with the listing; no per-row or per-frame git calls; dirty checks happen only inside the remove flow.

## Testing Decisions

- Good tests exercise **external behaviour through the public/pure interfaces** — feed input, assert output shape — never internal representation. This matches the existing suite's discipline.
- **Tested modules**: the repo/worktree porcelain parser, both branch-source parsers, and both operation planners (add + remove) — pure functions requiring no real git. The git runner is exercised indirectly as a mocked seam.
- **Untested by decision**: the TUI mode and browse rendering (consistent with the rest of the suite — the render/input loop has no test harness).
- **Prior art**: the existing Pester suites for the template expander, key resolver, command store, and keymap — `BeforeAll` module import, `InModuleScope` for non-exported functions, `$TestDrive` for any file fixtures, behaviour-only assertions. The suite's PS 5.1 source-grep guard pattern applies to any new generic-List usage.
- Planner tests must cover every destructive rule: main-worktree refusal, dirty-warning requirement, force-delete of unmerged branches without extra prompts, and exact naming of what gets deleted.

## Out of Scope

- Remote branch deletion (GitHub's delete-on-merge handles it; too destructive for surf).
- Per-project or per-directory configuration of any kind (reaffirming the custom-commands PRD's decision).
- Dirty-status markers on worktree rows (perf: no git status in the browse hot path).
- A `surf worktree` CLI subcommand — this is a TUI-only feature.
- Chained `w…` keys — `w` is a single entry point into one management area, by explicit decision.
- Any non-GitHub forge integration beyond the generic ls-remote fallback.

## Further Notes

- `gh` is not currently installed on the primary development machine, so the PR picker
  will exercise its ls-remote fallback there until it is; the gh path is still built and
  tested via its pure parser.
- The management area is the first mode whose text-input substates chain several prompts
  (branch → base → path). The search-input pattern generalises; keep each prompt's state
  explicit so Esc backs out one step at a time.
- Worktrees created by other tools (e.g. Claude Code's `.claude\worktrees\` convention)
  appear in the same lists automatically — surf reads git's registry, not its own.
