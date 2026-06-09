# `/ship` pipeline — drop-in bundle for `.claude/`

A spec -> critique -> phase -> plan -> critique -> implement -> verify loop for Elixir/Phoenix, built from Claude Code's real primitives: a skill orchestrator, read-only editor subagents, and a preloaded Elixir rubric.

## What's in here
```
agents/
  spec-editor.md          read-only Elixir architecture reviewer         (opus)
  plan-editor.md          read-only OTP/migration/LiveView plan reviewer  (opus)
  phase-agent.md          read-only spec->phases planner (returns JSON)   (sonnet)
skills/
  ship/SKILL.md           the /ship orchestrator (you type /ship)
  elixir-otp-rubric/      shared review standards, preloaded into both editors
```

## The composition (writer + your editor)
This is the design you asked for: an off-the-shelf **writer** drafts, your custom **editor** judges, the orchestrator loops.
- **Writer** = Claude's **native drafting**, run by the orchestrator. There is no discrete Anthropic "spec writer" tool, so native drafting *is* "Claude's spec writer." For the plan step, **Plan Mode** is Anthropic's genuine built-in plan writer and can be swapped in.
- **Editor** = your `spec-editor` / `plan-editor`. They are **read-only** by design (no Write/Edit): the writer writes, the editor judges, the orchestrator applies the edits. Naming them "editor" doesn't change that — the moment an editor rewrites, you've rebuilt the writer inside it.
- **Optional dependency:** Superpowers (`obra/superpowers`) ships `brainstorming` (spec) + `writing-plans` (plan). If you want it, install once and invoke those skills *only to draft* — and suppress Superpowers' own `spec-document-reviewer`, since your editors are the reviewers of record. The orchestrator has a one-line swap-in point for this. Not the default, because it adds a dependency, a competing reviewer, and its own worktree behavior.

## Fact-check of the prior thread (you asked)
- **`/loop` is a recurring cron timer**, session-scoped, max 3 days — *not* a convergence loop. It cannot drive critique loops. The native "iterate until a condition is met" primitive is **`/goal`**; this bundle implements convergence in the orchestrator itself (so it can apply the Critical/Major cap), which is the right place for the loop state. `scheduled_tasks.lock` is `/loop` runtime state — not part of this design; gitignore it.
- **Superpowers is real and verified.** `/plugin marketplace add obra/superpowers-marketplace` then `/plugin install superpowers@superpowers-marketplace`; also on the official Claude marketplace. Skills: `brainstorming`, `using-git-worktrees`, `writing-plans`, `subagent-driven-development`, `verification-before-completion`. Its `brainstorming` does ship a spec reviewer — that warning was correct.
- **"No Anthropic spec or plan writer" is half-right:** no spec-writer, but **Plan Mode / the `Plan` subagent** is Anthropic's plan writer, and `brainstorming` is third-party-authored yet Anthropic-*distributed*.
- **"Your agents become redundant under Superpowers" is overstated** — Superpowers has no Elixir/OTP/LiveView knowledge, which is the whole reason your editors exist. Keep them.

## What changed from the first cut of this bundle
- Renamed to your vocabulary: `spec-editor`, `plan-editor`, `phase-agent`.
- **Convergence cap added.** Loops run on **Critical/Major only**, **Minor is non-blocking** (logged to `open_items`), and each loop **caps at 3 passes** before proceeding with open items recorded. "Repeat until clean" could otherwise spin forever on Minors, since a critic told to assume flaws can always find one.
- **Empirical gates weighted over critique.** `mix dialyzer` added to the final gate; `git push` added (optional, asks first). A green `mix test` / `dialyzer` / `credo --strict` outranks a clean editor pass.
- Plan-draft step now uses your detailed step template (target files, migration commands, process topology, idiomatic outline, test plan, risk mitigation).

## Install (drop-in, merge-safe)
Put the zip inside your project's `.claude/` and unzip there:
```
cd your-project/.claude
unzip /path/to/ship-pipeline.claude.zip
```
You get `.claude/agents/...` and `.claude/skills/...`. **Nothing is overwritten** — no `settings.json`, no `CLAUDE.md`, no root `.gitignore` in this bundle, so it merges into an existing `.claude/` cleanly. Only collision risk: an existing agent named `spec-editor`/`plan-editor`/`phase-agent` or skills named `ship`/`elixir-otp-rubric`; rename the folder and `name:` field if so.

**Then restart Claude Code** (or run `/agents`). Subagents load at session start, and a `.claude/skills/` directory that didn't exist when the session started isn't watched until you restart.

Run it:
```
/ship billing_system
```

## How it stays portable across any project
- **No hardcoded paths or project names.** The orchestrator resolves the project name from `git rev-parse --show-toplevel` at load and writes *literal* resolved values into state. (The old version stored `{$self.project}` strings that never expanded.)
- **State is per-feature and gitignored** at `.claude/.pipeline/<feature>/state.json`, with a self-contained `.claude/.pipeline/.gitignore` (`*`) so it never enters version control and never touches your root `.gitignore`. Per-feature keying lets two features run without stomping each other.
- **Permissions travel with the skill.** The git/mix commands are in `ship/SKILL.md`'s `allowed-tools`, so it runs without a project `settings.json`. (Optional: copy them into `settings.json` `permissions.allow` to grant session-wide.)
- **Every bash command is self-contained.** `cd` and shell variables don't persist between tool calls, so the orchestrator never relies on a directory it set earlier — it uses `git -C` and `cd X && cmd` compounds.

## Models — do you need Opus for everything?
No. Opus where judgment is expensive to get wrong; cheaper models where bounded.

| Role | Model | Why |
|------|-------|-----|
| Orchestrator (`/ship`) | **your session model** | Sequencing + native drafting + implementation. `claude --model opus` for best results, or `--model sonnet` for the cost-optimized variant. |
| `spec-editor` | **opus** (pinned) | Catching functional-core / OTP / decoupling flaws is where the strongest model pays for itself. |
| `plan-editor` | **opus** (pinned) | Migration safety, supervision, reconnect — subtle, and mistakes cost data loss or deadlocks. |
| `phase-agent` | **sonnet** (pinned) | Decomposition is bounded. Bump to opus only if splits feel shallow. |

The editors pin Opus in frontmatter, so they run on Opus **even if the orchestrator runs on Sonnet**. That enables the cheap pattern: **draft on Sonnet, harden on Opus** — only the review passes cost Opus rates. Resolution order: `CLAUDE_CODE_SUBAGENT_MODEL` env (global override — leave unset) -> per-invocation -> frontmatter -> session. Optional further saving: a `verifier` subagent on **haiku** that runs `mix test` and returns only failures.

## Explicit skill loading (token control)
- The Elixir rubric is **preloaded only into the two editors** via their `skills:` frontmatter — its tokens never enter the orchestrator's context, and it's the single source of truth for the standards (no more duplicating the rubric across agents).
- `/ship` sets `disable-model-invocation: true`, so it runs **only** when you type `/ship` — never auto-triggered, never cluttering the ambient skill list.
- The rubric is `user-invocable: false` — hidden from the `/` menu, since it's machinery.
- To pull a bundled skill (`/code-review`, `/verify`) into a specific step, name it in the orchestrator at that step instead of relying on auto-load.

## Rename the command
The command name is the skill's **directory** name. For `/build` instead of `/ship`, rename `skills/ship/` -> `skills/build/` (and update the `name:` field for the listing label).

## Feature branch vs. worktree
The old design did `git worktree add ../<proj>_<feature>` and `cd` into it. In Claude Code that fights the tool model two ways: `cd` doesn't persist across Bash calls, and the file tools are scoped to the working-directory tree — a sibling `../<proj>_<feature>` is outside it, so reads/writes there get denied unless you `--add-dir` it. So this bundle works on a **feature branch in the main checkout**, which sidesteps both problems. For true parallel isolation, the modern path is the **`isolation: worktree`** frontmatter field on a subagent (Claude Code provisions and cleans up the worktree and handles file access), or Superpowers' own worktree handling. Either is a deliberate extension, not the default.

## Requirements
- A current Claude Code (2.1.x) for skills, the `skills:` preload field, and `disable-model-invocation`. `isolation: worktree`, if added, needs the worktrees feature.
- An Elixir/Phoenix project (mix.exs) for the gates and the Elixir-specific editors. The orchestrator detects mix.exs and warns if absent; the loop structure is language-agnostic but the rubric and `mix` gates are not.
