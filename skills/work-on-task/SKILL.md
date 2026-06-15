---
name: work-on-task
description: Orchestrate a dex task from validation through to an open PR. Delegates each phase to sub-agents and skills. Use when asked to "work on task", "start task", "pick up task", "do task", or given a dex task ID to implement.
---

# Work on Task

Orchestrator that drives a dex task through five phases, delegating real work to sub-agents and skills. Your job is to keep the process moving — not to do the implementation yourself.

## Arguments

- `$0` — A dex task ID or search query. If omitted, run `dex list` and ask which task to work on.

## Phase 1: Validate the Task

Fetch the task:

```bash
dex show <task_id> --full
```

The task **must** have:

- A clear, specific goal (what is the desired outcome?)
- Supporting context: hints, examples, links, or acceptance criteria

If either is missing or vague, **stop and fix the task first**. Spawn a sub-agent to research what's needed — read related code, issues, or docs — then update the task with concrete details:

```bash
dex edit <task_id> -d "<improved description>" --context "<added context>"
```

Do not proceed to Phase 2 until the task is actionable.

## Phase 2: Plan the Change

Spawn a **Plan agent** to investigate:

1. Is this change still needed? (Check if it was already done, superseded, or no longer relevant.)
2. What files and modules need to change?
3. What is the implementation approach?
4. Are there any blockers or dependencies?

If the investigation reveals the task is no longer needed, mark it done with a result explaining why, and stop.

Review the plan. If it looks right, proceed. If not, redirect the agent or adjust.

## Phase 3: Branch and Implement

### Branch

Always start from a fresh base:

```bash
git checkout master && git pull
git checkout -b <branch-name>
```

Use a descriptive branch name derived from the task (e.g., `feat/add-user-auth`, `fix/null-pointer-processor`).

### Implement

Spawn a sub-agent to implement. The agent must follow **TDD**:

1. Write a failing test that captures the desired behavior.
2. Write the minimum code to make the test pass.
3. Refactor if needed, keeping tests and lint green.
4. Use the /commit skill to preserve progress.
4. Repeat until the task's goal is met.

Keep changes focused on the task — no unrelated refactors or improvements.

## Phase 4: Review and Fix

Run these review passes and fix every issue before moving on.

### 4a: Frontend Conventions

Run `/frontend-conventions` on the changed files. Fix all findings.

### 4b: Code Review

Run `/review` on the current branch. Fix all findings.

### 4c: Tests and Lints

Run the project's test suite and linter. Everything must pass. If there are type checks, run those too.

Repeat 4a–4c until clean.

## Phase 5: Ship It

### Create the PR

Run `/pr-writer` to commit, push, and open the pull request in draft mode.

Add comments to the PR explaining chunks of code that was moved around within the diff, or that's copy+pasted within the file, or if the code is removed why it isn't needed anymore (unless it's obviously the purpose of the PR).

### Track the PR

Create a sub-task under the original task to track the open PR until it merges:

```bash
dex create -d "Track PR: <pr_url>" --context "PR must be merged before parent task is done." --parent <task_id>
```

Then run `/depend-on-pr <pr_url>` to set up monitoring.

The original task is **not done** until the PR is merged.

### Report

Print the PR URL and a one-line summary of what was shipped.

## Stop Conditions

Pause and ask the user before proceeding when:

- The task description is ambiguous after your best attempt to improve it
- The plan reveals the change is risky or much larger than expected
- Tests are failing and the fix is non-obvious
- The task depends on work that hasn't been completed yet
