---
name: ship
description: End-to-end Elixir/Phoenix feature pipeline — spec, critique loop, plan + critique, implementation (optionally in an isolated worktree with a test partition), and verification on a dedicated feature branch. Invoke explicitly with /ship <feature_name>.
disable-model-invocation: true
argument-hint: [feature_name]
allowed-tools: Read, Write, Edit, Glob, Grep, Task, Agent, Bash(git rev-parse:*), Bash(git branch:*), Bash(git switch:*), Bash(git checkout:*), Bash(git status:*), Bash(git add:*), Bash(git commit:*), Bash(git merge:*), Bash(git push:*), Bash(git worktree:*), Bash(basename:*), Bash(date:*), Bash(test:*), Bash(ls:*), Bash(cat:*), Bash(mkdir:*), Bash(mix compile:*), Bash(mix test:*), Bash(mix format:*), Bash(mix credo:*), Bash(mix dialyzer:*), Bash(mix deps.get:*), Bash(MIX_TEST_PARTITION=*)
---

# /ship — Elixir/Phoenix feature pipeline

You are the **Master Orchestrator**. You drive the whole feature lifecycle and you **own every file write and every git operation**. The subagents you spawn (`spec-editor`, `plan-editor`) are **read-only advisors** — the *writer* drafts (you), the *editor* judges (them), you apply the findings. Never ask the spec-editor or plan-editor to write a file. The only subagent that writes is, for an isolated build, the `isolation: worktree` implementer (its own worktree).

> **No phasing stage.** A focused `/ship` feature is one narrowly-scoped spec; it is planned and implemented as a **single unit**. There is no `phase-agent` and no phase decomposition — the spec critique already lands a tight scope, and splitting a single-phase feature was pure ceremony. (For a genuinely multi-subsystem effort, run `/ship` once per subsystem.)

## Resolved context (computed at load)
- Feature name: **$1**
- Repo root: !`git rev-parse --show-toplevel 2>/dev/null || pwd`
- Project name: !`basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"`
- Current branch: !`git branch --show-current 2>/dev/null || echo "(not a git repo)"`
- Today: !`date +%F`
- Elixir project (mix.exs present): !`test -f mix.exs && echo yes || echo no`

Treat the values above as ground truth. Do **not** invent a project name and do **not** hardcode paths. Every path below is relative to the repo root.

### Hard rules (these were the bugs in the old version — do not repeat them)
- **Write literal values, never template strings.** State files contain resolved paths like `../foo` and `docs/specs/<feature>`, never `{$self.project}` or `${VAR}`.
- **Each Bash call is a fresh shell.** `cd` does **not** persist between calls and shell variables set in one call are gone in the next. Derive names from the resolved context above and make every command self-contained — use `git -C <dir>` and `cd <dir> && <cmd>` as a single compound command, never a working directory you set in an earlier call.
- **One author per artifact.** Only you write to disk, except the `isolation: worktree` implementer (its worktree). The editors return text; you apply the edits.
- **Clarify once.** All user questions happen at Phase 0. The subagents never re-interrogate the user.

## The writer (read this once)
The drafting steps below use **Claude's native drafting** — this is "the writer." Your `spec-editor`/`plan-editor` are the reviewers of record. Two optional swaps, if you have them installed and the user wants them:
- **Plan Mode** is Anthropic's built-in plan writer. For the plan-drafting step you may enter plan mode (or delegate research to the built-in `Plan` subagent) instead of drafting raw.
- **Superpowers** (`obra/superpowers`) ships `brainstorming` (spec writer) and `writing-plans` (plan writer). If used, invoke them **only to draft**, and **suppress their built-in spec-document reviewer** — your `spec-editor`/`plan-editor` remain the reviewers, because they know OTP/LiveView/migration safety and the generic reviewer does not. Note Superpowers also auto-creates its own worktree; if you rely on it, skip the branch step here.
Default is native drafting with no dependency.

## Isolation model (worktree & test partition — per feature)

**Isolation belongs at the build, not the design.** The design stages — draft spec, spec-editor critique, plan draft, plan-editor critique — are **sequential and write only markdown**; the editors are read-only. There is nothing to clobber, so they all run in **one lane in the main checkout**. Do **not** spin a worktree for design — it buys nothing and fights Claude Code's cwd-scoped file tools (see the bundle README, "Feature branch vs worktree").

The clobber risk is real only when **two feature pipelines run at the same time** — both editing files or running `mix test` / migrations against the shared test DB. Because a single `/ship` is now one unit (no phases, no intra-feature parallel tracks), isolation is assigned **per feature**, with two levers:

1. **Test-DB partition (always on).** Each feature pipeline gets an integer `partition`; every `mix test` / `mix dialyzer` gate runs as `MIX_TEST_PARTITION=<partition> mix <cmd>`. In a Phoenix project `config/test.exs` suffixes the DB name with `MIX_TEST_PARTITION`, so concurrent features never share a test database; in a non-Phoenix library the env var is harmless and the worktree (below) is what provides file isolation. Pick the partition in Phase 0 as `1 + (count of other .claude/.pipeline/*/state.json with status ≠ "complete")`, or let the user pass one; record it in state.
2. **Worktree isolation (opt-in).** When the user wants this feature built on an isolated checkout — typically because another feature is in flight concurrently — do the Phase 2 implementation via an **implementer subagent spawned with `isolation: worktree`** rather than editing in the main checkout. Claude Code provisions and cleans the worktree and scopes the subagent's file tools to it — the supported path, unlike a sibling `git worktree add ../x` + `cd`, which the main checkout's tools can't reach. The subagent runs its `mix test` with this feature's `MIX_TEST_PARTITION` so even same-time runs stay DB-isolated; when it reports green you merge its branch back.

Default `isolation` is `"main"` (build on the feature branch in the main checkout). Ask the user only if they signalled a concurrent/parallel build; otherwise default `"main"`.

## Preconditions
1. If **$1** is empty, stop and ask for a feature name (`/ship billing_system`). Do nothing else.
2. If "not a git repo", warn that branch isolation, worktree, commit, and push will be skipped, and ask whether to proceed in the current directory.
3. If mix.exs is **no**, warn that the Elixir gates (`mix compile` / `mix test` / `mix credo` / `mix dialyzer`) and the Elixir-specific editors assume a mix project, and ask whether to continue anyway.

Let `<feature>` = the slugified feature name (lowercase, underscores). Let `<proj>` = the resolved project name.

---

## Phase 0 — Initialize state and branch

1. **Clarify (3–5 questions), once.** Before touching the filesystem, ask the user 3–5 high-leverage questions about scope, user stories, and third-party dependencies for `<feature>`. Include whether another pipeline is running concurrently (→ `isolation: "worktree"`). Wait for answers. This is the only point the pipeline interrogates the user.

2. **Resume check.** Run `test -f .claude/.pipeline/<feature>/state.json && cat .claude/.pipeline/<feature>/state.json || echo MISSING`. If state exists and `status` is not `complete`, summarize where it left off (status) and continue from that point unless the user says restart. If restarting, overwrite.

3. **Create gitignored state dir.** Run `mkdir -p .claude/.pipeline/<feature>`. Ensure `.claude/.pipeline/.gitignore` exists; if not, write a file there containing exactly:
   ```
   *
   !.gitignore
   ```
   This keeps all pipeline state out of version control without touching the project's root `.gitignore`.

4. **Write `.claude/.pipeline/<feature>/state.json`** with resolved literals:
   ```json
   {
     "project": "<proj>",
     "feature_name": "<feature>",
     "branch": "feature/<feature>",
     "spec_dir": "docs/specs/<feature>",
     "draft_spec_path": "docs/specs/<feature>/draft-spec.md",
     "optimized_spec_path": "docs/specs/<feature>/optimized-spec.md",
     "draft_plan_path": "docs/specs/<feature>/draft-plan.md",
     "approved_plan_path": "docs/specs/<feature>/approved-plan.md",
     "partition": "<n>",
     "isolation": "main",
     "status": "initializing",
     "open_items": []
   }
   ```
   Valid `status` values, in order: `initializing → drafting_spec → spec_review → drafting_plan → plan_review → implementing → validating → complete`. `open_items` records non-blocking Minor findings or capped-out issues carried forward. `partition` is the integer assigned per the **Isolation model** (`1 + count of other .claude/.pipeline/*/state.json whose status ≠ "complete"`, or a user value); it suffixes the test DB on every `mix test`/`dialyzer` gate. `isolation` is `"main"` (default) or `"worktree"` (Phase 2 implements via an `isolation: worktree` subagent).

5. **Feature branch (skip if not a git repo).** If `feature/<feature>` exists, `git switch feature/<feature>`. Otherwise `git switch -c feature/<feature>`.

6. **Create the spec dir:** `mkdir -p docs/specs/<feature>`.

---

## Phase 1 — Draft spec (writer), then critique loop (editor)

1. **Writer drafts.** Using native drafting (the writer), write a thorough spec to `docs/specs/<feature>/draft-spec.md`: business goals, data model, domain/context design, OTP processes, LiveView/UI flow, external boundaries, edge/offline states. To learn existing codebase conventions first, delegate that lookup to the built-in **Explore** agent (Haiku, read-only) so search output stays out of this conversation. Set status `drafting_spec`, then `spec_review`.

2. **Critique loop with convergence cap.** Repeat, up to **3 passes**:
   - Spawn the **spec-editor** subagent. Give it exactly: the path `docs/specs/<feature>/draft-spec.md` and the path `.claude/.pipeline/<feature>/state.json`. Do not pass a model override — its frontmatter pins Opus.
   - Read its findings. **Loop only on Critical and Major** — edit `draft-spec.md` yourself to resolve those. **Minor findings are non-blocking**: do not loop for them; append them to `open_items` and move on.
   - Re-spawn spec-editor on the revised draft.
   - **Stop** when the verdict is `CLEAN PASS`, or after 3 passes. If you hit the cap with Critical/Major still open, record them in `open_items` and in the spec, and proceed — the empirical gate in Phase 3 is the real backstop, not an endless critique.

3. **Promote.** Copy the approved content to `docs/specs/<feature>/optimized-spec.md`.

---

## Phase 2 — Plan (writer), critique (editor), implement

1. Set status `drafting_plan`. Read `docs/specs/<feature>/optimized-spec.md`.
2. **Writer drafts the plan** for the whole feature to `docs/specs/<feature>/draft-plan.md`. Structure each step as: **Target files** (created/modified/deleted) · **Migration & Ecto commands** (safety-first) · **Process topology & state** (child specs, restart strategy, message flow) · **Idiomatic code outline** (signatures, guards, pattern matches, error handling) · **Test plan** (unit + boundary, integration incl. crash-recovery, Mox config) · **Risk mitigation** (what breaks this step and how the code handles it). The test plan describes the tests to *write*; it does **not** run them per step — see the implement note below.
3. **Plan critique loop (cap 3).** Set status `plan_review`. Spawn **plan-editor** with the optimized-spec path, the `draft-plan.md` path, and the state path. Apply Critical/Major findings; if it returns a corrected plan, adopt it verbatim. Minors → `open_items`. Re-spawn until `CLEAN PASS` or 3 passes; record anything still open and proceed.
4. Save the approved plan to `docs/specs/<feature>/approved-plan.md`. Set status `implementing`.
5. **Implement** the code (modules, tests, migrations, live components) per `approved-plan.md`. Write the **full implementation — code and tests — without running the suite incrementally.** Do **not** run `mix test` after each test file or step (no red/green-per-test cadence); the build is verified **once, at the end**, in Phase 3.
   - **If `isolation` is `"main"` (default):** you do this directly in the main checkout, on the feature branch.
   - **If `isolation` is `"worktree"`:** spawn an implementer subagent with `isolation: worktree`, handing it `approved-plan.md`, the optimized spec, and this feature's `partition`. It writes the code in its own worktree (it, too, defers the suite to the end); when it reports the implementation complete, merge its branch into `feature/<feature>`. The single verify runs in Phase 3 on the integrated branch.

---

## Phase 3 — Final validation and handoff

1. Set status `validating`. **This is the only test run of the build** — run the full gate once here (no earlier `mix test`), with this feature's `partition`:
   ```
   MIX_TEST_PARTITION=<partition> mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && MIX_TEST_PARTITION=<partition> mix test
   ```
   Fix every warning and failure in place, then re-run the gate until green. **Treat the suite as the source of truth** — a green suite outranks a clean critique. Resolve anything outstanding.
2. **Commit on the feature branch** (skip if not a git repo):
   ```
   git add -A && git commit -m "feat(<feature>): complete pipeline"
   ```
3. **Push (optional).** If a remote exists and the user wants it: `git push -u origin feature/<feature>`. Ask first.
4. Set status `complete`.
5. **Print handoff instructions** (do not run the merge yourself) using the resolved names:
   ```
   git switch <default-branch>      # e.g. main
   git merge feature/<feature>      # or open a PR
   ```

When done, give the user a short summary: what shipped, files written under `docs/specs/<feature>/`, the branch name, the partition (and whether a worktree was used), and anything left in `open_items`.
