---
description: "Global workflow (revised 2026-07-22 to Opus 4.8/Fable 5 orchestrator + role-split executor tiers + HARD delegation rules). Main session is Opus 4.8 (`claude-opus-4-8-thinking-high`) by default, with Fable 5 (`claude-fable-5-high`) as an acceptable alternative; the Orchestrator MUST delegate Write/Edit/Read/Shell past hard numerical thresholds to Executor subagents split by role: Composer 2.5 Fast (`composer-2.5-fast`) for volume executors (`generalPurpose`, `explore`, `shell`, `best-of-n-runner`), Sonnet 5 (`claude-sonnet-5-thinking-medium`) for reviewer/judgement subagents. A preToolUse hook (~/.cursor/hooks/enforce-large-write.sh) blocks direct Orchestrator Writes >30 lines. Dispatched Composer/Sonnet Executor subagents must NOT re-dispatch Task() to equal-tier agents. Use superpowers skills (brainstorming, writing-plans, executing-plans, dispatching-parallel-agents, using-git-worktrees, verification-before-completion). DO NOT use gsd-* (archived) or claude-mem skills (make-plan/do/learn-codebase)."
alwaysApply: true
---

# Global Workflow Conventions

User-level defaults across every Cursor workspace. **User instructions in chat win.**

## Default model: Opus 4.8. Opus MUST delegate execution.

The main session runs on **Opus 4.8** (`claude-opus-4-8-thinking-high`), with **Fable 5** (`claude-fable-5-high`) as an acceptable alternative for the main session, because architectural reasoning, plan synthesis, review judgement, and multi-source integration benefit from depth. Direct Opus writes/edits are far more expensive than either Executor tier below — roughly **5x Sonnet 5**, and cheaper still relative to **Composer 2.5 Fast**, the default for volume/mechanical work. To make cost discipline structural rather than aspirational, the Orchestrator operates under hard numerical delegation rules below — backed by a `preToolUse` hook at `~/.cursor/hooks/enforce-large-write.sh` that blocks Write tool calls >30 lines from the main session.

| Operation | Model |
|---|---|
| Main chat (default) | **`claude-opus-4-8-thinking-high`** |
| Main chat (alternative) | `claude-fable-5-high` |
| Plan Mode | `claude-opus-4-8-thinking-high` (already there) |
| `Task()` volume dispatch — default (`generalPurpose`, `explore`, `shell`, `best-of-n-runner`), incl. heavy mechanical edits | **`composer-2.5-fast`** |
| Reviewer/judgement subagents (`go-expert`, `postgres-expert`, `prompt-engineer`, `slack-expert`, `test-writer`, `code-reviewer`, `plan-verifier`, `requirements-planner`, `youtrack-task-writer`) | Sonnet 5 (set in their frontmatter) |

## Delegation hierarchy — two tiers only

| Tier | Who | Model | May use `Task()`? |
|------|-----|-------|-------------------|
| **Orchestrator** | Main chat session only | `claude-opus-4-8-thinking-high` or `claude-fable-5-high` | **Yes** — dispatches Tier-2 executors |
| **Executor (volume)** | Dispatched `generalPurpose`, `explore`, `shell`, `best-of-n-runner` | `composer-2.5-fast` | **No** — execute work directly |
| **Executor (reviewer)** | Dispatched `go-expert`, `postgres-expert`, `prompt-engineer`, `slack-expert`, `test-writer`, `code-reviewer`, `plan-verifier`, `requirements-planner`, `youtrack-task-writer` | `claude-sonnet-5-thinking-medium` | **No** — execute work directly |

**Critical rule:** HARD delegation thresholds (Rules 1–5 below) apply **only to the Orchestrator tier**. When you are a dispatched Composer or Sonnet subagent, you are an Executor — do **not** spawn `Task()` subagents for work you were dispatched to do. Read, write, edit, and shell directly within your prompt scope.

**Forbidden:** Executor → `Task(..., model=composer-2.5-fast)` or `Task(..., model=claude-sonnet-5-thinking-medium)` for mechanical execution (equal-tier re-delegation).
**Allowed:** Orchestrator → `Task(..., model=composer-2.5-fast)` for volume work, or `Task(..., model=claude-sonnet-5-thinking-medium)` for reviewer/judgement work, per Rules 1–5.

## HARD RULES — check BEFORE every tool call

### Rule 1 — Writing files (Write tool)

| File size                | Action                                                                |
|--------------------------|-----------------------------------------------------------------------|
| >30 lines                | STOP. Dispatch `Task(generalPurpose, model="composer-2.5-fast")`. |
| 10–30 lines, mechanical  | Prefer Task. Direct Write only with user reviewing inline.            |
| <10 lines, hand-written  | Direct Write OK.                                                      |

A `preToolUse` hook at `~/.cursor/hooks/enforce-large-write.sh` blocks any Write with >30 lines from the main session and returns an `agent_message` reminder. Subagent Writes pass through.

Multiple small files in a row (≥2) → batch into ONE Task dispatch.

### Rule 2 — Editing files (StrReplace / Edit tools)

| Edit volume                    | Action                                                                |
|--------------------------------|-----------------------------------------------------------------------|
| Single edit, <10 lines diff    | Direct StrReplace OK.                                                 |
| ≥2 edits (same or multi-file)  | STOP. Dispatch `Task(generalPurpose, composer)` with full list.      |

### Rule 3 — Reading files (Read tool)

| Read volume                    | Action                                                       |
|--------------------------------|--------------------------------------------------------------|
| 1–2 files                      | Direct Read OK.                                              |
| ≥3 files for analysis          | STOP. Dispatch `Task(explore, composer)`.                    |

Exception: file the user is currently editing or which is the literal subject of the question.

### Rule 4 — Shell context-gathering

| Command volume                 | Action                                                       |
|--------------------------------|--------------------------------------------------------------|
| 1–2 quick commands             | Direct Shell OK (`git status`, `ls`).                        |
| ≥3 commands for context        | STOP. Dispatch `Task(shell, composer)` with batched commands. |

### Rule 5 — Self-audit at start of every response

Before issuing ANY tool call, count what the current plan implies:

- Planned Write+Edit operations total ≥2 → one Task dispatch instead.
- Planned Read operations total ≥3 → Task(explore, composer).
- Planned shell commands for context ≥3 → Task(shell, composer).
- Any single file >30 lines being written → Task(generalPurpose, composer).

If ANY threshold trips, the FIRST tool call in the response must be the Task dispatch.

## Dispatch templates (use verbatim)

```
Task(
  subagent_type: "generalPurpose",
  model: "composer-2.5-fast",
  description: "<5-word title>",
  prompt: "<full spec: paths, content verbatim or specs, acceptance criteria, lints to pass>"
)

Task(
  subagent_type: "explore",
  model: "composer-2.5-fast",
  description: "<5-word title>",
  prompt: "<question + directory + expected return shape>"
)

Task(
  subagent_type: "shell",
  model: "composer-2.5-fast",
  description: "<5-word title>",
  prompt: "<exact commands, working dir, expected output>"
)
```

Reviewer/judgement subagents (`go-expert`, `test-writer`, `plan-verifier`, etc.) keep their own frontmatter model (`claude-sonnet-5-thinking-medium`) — do not pass `composer-2.5-fast` for those dispatches.

Removed subagents (do not reference):
- `implementor`, `react-reviewer`, `react-ts-expert` — not used in this workflow (2026-07-05)

## What Opus DOES directly

- Read 1–2 relevant files for reasoning.
- 1–2 inline shell commands for orientation.
- StrReplace edits ≤1 per response, ≤10 lines.
- Plan documents, ADRs, design conversations, review verdicts (in chat, not as files).
- Synthesis of subagent results.
- Direct user dialogue.

## What Opus NEVER does directly

- Write a file >30 lines.
- Apply ≥2 edits in one response.
- Read ≥3 files for analysis.
- Run ≥3 context-gathering shell commands.
- Multi-file refactors.
- Migration writing.

## Anti-rationalisation list

| Tempting thought                                | Reality                                                  |
|-------------------------------------------------|----------------------------------------------------------|
| "It's faster if I do it directly"               | Composer/Sonnet subagent returns in 10–30s. Count seconds. |
| "I already have the context"                    | Pass it in the prompt.                                   |
| "Just this one file"                            | Measure lines. >30? Dispatch.                            |
| "Simple mechanical edit"                        | Simple → Composer handles it trivially. Dispatch.        |
| "The user is waiting"                           | Burning budget makes them wait longer. Dispatch.         |
| "Subagent might miss context"                   | Pass exact paths and snippets.                           |
| "I'll just start and switch later"              | No. First tool call = the dispatch.                      |
| "The hook will catch me if I'm wrong"           | The hook is a safety net, not a steering wheel.          |

## Three workflow patterns

**Pattern A — Parallel isolated agents** (multiple independent features):
- `best-of-n-runner` subagent (auto git-worktree), or
- `using-git-worktrees` superpowers skill (manual)

**Pattern B — Plan in Opus, execute in Composer** (one big feature):
1. Plan Mode in Cursor (Opus) or `writing-plans` skill → PLAN.md
2. Back to Agent (Opus) → dispatch each atomic step to `Task(generalPurpose, composer)`
3. Executor invokes the relevant workspace skill before coding (e.g. under `<repo>/.cursor/skills/`)
4. `verification-before-completion` skill before any "done" claim

**Pattern C — Parallel reviewer sub-agents** (tests + lang-review + plan-verify on one PR):
- ONE message with multiple parallel `Task(...)` calls, all Sonnet
- Typical fan-out: `test-writer`, `go-expert` (backend), `plan-verifier`
- See `dispatching-parallel-agents` skill
- `youtrack-task-writer` formats/creates YouTrack tasks for DevOps work (separate from GitLab)

## Skill priority

- `brainstorming` — before ANY creative work
- `writing-plans` — after brainstorming, before code
- `executing-plans` — execute plan with review checkpoints
- `subagent-driven-development` — parallel tasks in current session
- `dispatching-parallel-agents` — 2+ independent tasks
- `using-git-worktrees` — isolation
- `verification-before-completion` — before "done" claims
- `requesting-code-review` / `receiving-code-review`
- `finishing-a-development-branch` — merge/PR/cleanup decision
- `systematic-debugging` — any bug or unexpected behavior
- `test-driven-development` — when implementing features

Workspace-specific skills under `<repo>/.cursor/skills/` win over global skills.

## DO NOT use

- `claude-mem` skills (`make-plan`, `do`, `learn-codebase`, `pathfinder`, `smart-explore`) — use superpowers equivalents. The `claude-mem` plugin's memory feature stays active; only its skills are off-limits.
- `gsd-*` anything — archived 2026-05-16 to `~/temp/dotfiles-cleanup-2026-05-16/`.
- Disabling the `~/.cursor/hooks/enforce-large-write.sh` hook without replacement.

## Cost discipline

1. Opus default but Opus delegates — hard rules above
2. Batch parallel `Task()` calls in ONE message — prompt cache stays warm
3. Use `context-mode` plugin for large tool outputs
4. Lean on `claude-mem` cross-session memory — don't re-explain known context
5. Plan Mode for big decisions — small edits go straight to Composer dispatch
6. Healthy week: Executor tokens (Composer volume + Sonnet reviewers) >70%, Opus <30%

## Workspace anti-patterns

- Editing `<repo>/.claude/agents/*.md` directly — symlinks. Edit `<repo>/.cursor/agents/*.md` source.
- Sequential `Task()` calls when they could be parallel.
- Re-running already-memoized tools in the same session.
- Hesitating to dispatch reviewer subagents — Sonnet review (~$0.02) is trivial vs catching bugs late.
- Executor subagent (Composer or Sonnet) re-dispatching `Task()` for work it should execute itself — Executors do not delegate; only the Orchestrator does.
