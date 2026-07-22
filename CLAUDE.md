# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.


# Global workflow conventions

User instructions in the chat ALWAYS win. The rules below are defaults for when the user did not specify otherwise.

---

## Default model is Opus 4.8. Opus MUST delegate execution.

The main session runs on **Opus 4.8** (`claude-opus-4-8-thinking-high`), with **Fable 5** (`claude-fable-5-high`) as an acceptable alternative for the main session, because architectural reasoning, plan synthesis, review judgement, and multi-source integration benefit from depth.

But direct Opus writes/edits are roughly **5x more expensive than Sonnet 5** (Opus ≈ $15/$75 per M tokens vs Sonnet ≈ $3/$15). Without discipline this burns budget on mechanical work Sonnet does equally well.

The contract for every session is therefore:

> **Opus THINKS, DECIDES, DELEGATES, and VERIFIES.**
> **Opus does NOT write code, run long shell pipelines, or read large file sets directly past the thresholds below.**

The thresholds in this file are HARD numerical triggers, not preferences. If a trigger fires, you STOP the in-progress tool call and dispatch a `Task(...)` Sonnet 5 subagent (`claude-sonnet-5-thinking-high`) instead. No exceptions for "I already have the context" or "it's just one file". A Cursor `preToolUse` hook at `~/.cursor/hooks/enforce-large-write.sh` enforces the Write rule programmatically.

---

## Delegation hierarchy — two tiers only

| Tier | Who | Model | May use `Task()`? |
|------|-----|-------|-------------------|
| **Orchestrator** | Main chat session only | `claude-opus-4-8-thinking-high` or `claude-fable-5-high` | **Yes** — dispatches Tier-2 executors |
| **Executor** | Dispatched subagents (`generalPurpose`, `explore`, `shell`, reviewers, `best-of-n-runner`) | `claude-sonnet-5-thinking-high` | **No** — execute work directly |

**Critical rule:** HARD delegation thresholds (Rules 1–5 below) apply **only to the Orchestrator tier**. When you are a dispatched Sonnet subagent, you are an Executor — do **not** spawn `Task()` subagents for work you were dispatched to do. Read, write, edit, and shell directly within your prompt scope.

**Forbidden:** Sonnet → `Task(..., model=claude-sonnet-5-thinking-high)` for mechanical execution (equal-tier re-delegation).
**Allowed:** Orchestrator → `Task(..., model=claude-sonnet-5-thinking-high)` per Rules 1–5.

---

## HARD RULES — check BEFORE every tool call

### Rule 1 — Writing files (Write tool)

| File size                | Action                                                        |
|--------------------------|---------------------------------------------------------------|
| >30 lines                | STOP. Dispatch `Task(generalPurpose, model=claude-sonnet-5-thinking-high)`. |
| 10–30 lines, mechanical  | Prefer Task. Direct Write only when user reviewing inline.    |
| <10 lines, hand-written  | Direct Write OK.                                              |

Multiple small files in a row (≥2) → batch into ONE `Task(generalPurpose, sonnet)` dispatch, do not call Write twice.

### Rule 2 — Editing files (Edit / StrReplace tools)

| Edit volume                    | Action                                                        |
|--------------------------------|---------------------------------------------------------------|
| Single edit, <10 lines diff    | Direct StrReplace OK.                                         |
| ≥2 edits (same or multi-file)  | STOP. Dispatch `Task(generalPurpose, sonnet)` with full list. |

### Rule 3 — Reading files (Read tool)

| Read volume                    | Action                                                       |
|--------------------------------|--------------------------------------------------------------|
| 1–2 files                      | Direct Read OK.                                              |
| ≥3 files for analysis          | STOP. Dispatch `Task(explore, sonnet)` with the question.    |

Exception: the file the user is currently editing or which is the literal subject of the question — read directly.

### Rule 4 — Shell context-gathering

| Command volume                 | Action                                                       |
|--------------------------------|--------------------------------------------------------------|
| 1–2 quick commands             | Direct Shell OK (`git status`, `ls`, short `head`).          |
| ≥3 commands for context        | STOP. Dispatch `Task(shell, sonnet)` with batched commands.  |

### Rule 5 — Self-audit at start of every response

Before issuing ANY tool call, count what the current plan implies:

- Planned Write+Edit operations total ≥2 → must be one Task dispatch.
- Planned Read operations total ≥3 → must be Task(explore, sonnet).
- Planned shell commands for context ≥3 → must be Task(shell, sonnet).
- Any single file >30 lines being written → must be Task(generalPurpose, sonnet).

If ANY threshold trips, the FIRST tool call in the response must be the Task dispatch. No "I'll just start and switch later".

---

## Dispatch templates (use these verbatim)

### Writing or editing a non-trivial file
```
Task(
  subagent_type: "generalPurpose",
  model: "claude-sonnet-5-thinking-high",
  description: "<5-word title>",
  prompt: "<full spec: paths, content verbatim or specs, acceptance criteria, lints to pass>"
)
```

### Reading/analysing many files
```
Task(
  subagent_type: "explore",
  model: "claude-sonnet-5-thinking-high",
  description: "<5-word title>",
  prompt: "<the question + which directory + expected return shape>"
)
```

### Long shell pipeline
```
Task(
  subagent_type: "shell",
  model: "claude-sonnet-5-thinking-high",
  description: "<5-word title>",
  prompt: "<exact commands, working dir, expected output>"
)
```

---

## What Opus DOES do directly

- Read 1–2 relevant files for high-level reasoning.
- 1–2 inline shell commands for orientation (`git status`, `ls`).
- StrReplace edits ≤1 per response, ≤10 lines.
- Plan documents, ADRs, design conversations, review verdicts (in chat, not as files).
- Synthesis of subagent results into a final answer.
- Direct user dialogue (questions, clarifications, summaries).

## What Opus NEVER does directly

- Write a file >30 lines.
- Apply ≥2 edits in one response.
- Read ≥3 files for analysis.
- Run ≥3 context-gathering shell commands.
- Multi-file refactors.
- Test runs that take >10s (dispatch to shell subagent).
- Migration writing (always Task(generalPurpose, sonnet) + plan-verifier review).

---

## Anti-rationalisation list (these are NOT valid reasons to skip dispatch)

| Tempting thought                                | Reality                                                  |
|-------------------------------------------------|----------------------------------------------------------|
| "It's faster if I do it directly"               | Sonnet subagent returns in 10–30s. Count actual seconds. |
| "I already have the context"                    | Pass it in the prompt. That's what prompts are for.      |
| "Just this one file"                            | Measure: how many lines? >30? Dispatch.                  |
| "Simple mechanical edit"                        | Simple → Sonnet handles trivially. Dispatch.             |
| "The user is waiting"                           | The user waits longer when Opus burns budget. Dispatch.  |
| "Subagent might miss context"                   | Pass exact paths and snippets in the prompt.             |
| "I'll just start and dispatch the rest later"   | No. The first tool call must be the dispatch.            |
| "The hook will catch me if I'm wrong"           | Don't lean on the hook. The hook is a safety net, not a steering wheel. |

---

## Skill priority

Both Opus (main session) and dispatched Sonnet subagents honour these skills, in this priority — but note that Sonnet subagents honour the *skills* while NOT inheriting the Task() delegation rules above, which are Orchestrator-tier only:

1. Process skills first: `brainstorming`, `systematic-debugging`, `writing-plans`, `executing-plans`, `verification-before-completion`.
2. Implementation skills second: workspace-specific skills under `<repo>/.cursor/skills/`, then global skills.

Opus is responsible for *invoking* the skill at the right moment. Sonnet subagents inherit skill instructions via the dispatch prompt, but execute directly rather than re-dispatching further `Task()` calls.

---

## Cost tracking heuristic

A healthy week shows Sonnet ≫ Opus tokens. Concretely:

- Sonnet input + output tokens > 70% of total.
- Opus input + output tokens < 30% of total.

If the Opus share trends above 30%, the delegation rules above are being skipped. Pause, re-read this file, and dispatch the next chunk to Sonnet.

---

## DO NOT use

- `claude-mem` skills (`make-plan`, `do`, `learn-codebase`, `pathfinder`, `smart-explore`) — use superpowers equivalents (`writing-plans`, `executing-plans`, etc.). The `claude-mem` plugin's cross-session memory feature stays active; only its skills are off-limits.
- `gsd-*` anything — archived 2026-05-16 to `~/temp/dotfiles-cleanup-2026-05-16/`.
- Editing `<repo>/.claude/agents/*.md` directly — those are symlinks. Edit `<repo>/.cursor/agents/*.md` source.

---

## Workspace anti-patterns

- Sequential `Task()` calls when they could be parallel — batch in one message.
- Re-running tools already memoized in the session — check first.
- Hesitating to dispatch reviewer subagents — Sonnet review (~$0.02) is trivial vs catching bugs late.
- Disabling the `~/.cursor/hooks/enforce-large-write.sh` hook without replacement — that hook is the structural safety net for Rule 1.
- Sonnet subagent re-dispatching `Task()` for work it should execute itself — Executors do not delegate; only the Orchestrator does.