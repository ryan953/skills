# tasklist plugin

Tasks and their PRs, tracked through one state machine. The rules, the SQLite
schema and an interactive map are in [`model/`](model/README.md).

## Install

```
/plugin marketplace add ryan953/skills
/plugin install tasklist@ryan953-skills
```

## Skills

Type a skill by its bare name, such as `/merge-pr`. If another command already
uses that name, use the namespaced form, `/tasklist:merge-pr`. Claude also
picks these up from their descriptions without being asked by name.

All thirteen are **stubs**. Each gives its state change, which PR kinds it
applies to, its preconditions and its `schema.sql` writes, with the remaining
steps marked TODO.

| Skill | Event(s) | Who |
|-------|----------|-----|
| `enter-task` | ENTER | you |
| `start-task` | START | you |
| `decompose-task` | DECOMPOSE (+ ENTER per subtask) | you |
| `create-pr` | PR_CREATED, new `mine` PR | you |
| `mark-done` | COMPLETE (tasks with no PRs) | you |
| `fix-pr` | NEW_COMMITS: self-review & push fixes | you, on `mine` and `bot` |
| `address-feedback` | COMMENT_REPLIED | you, on `mine` |
| `review-pr` | COMMENT_ADDED: review & comment | you, on `other` |
| `accept-pr` | ACCEPTED | you, on `bot` and `other` |
| `merge-pr` | MERGED | you, on `mine` and `bot` |
| `close-pr` | CLOSED, and the task's PR_CLOSED step-back | you, on `mine` and `bot` |
| `detect-prs` | DETECTED, plus everything others and CI do | external system |
| `settle` | AUTO_DONE, cascading to parents | automatic |

## Layout

```
plugins/tasklist/
├── .claude-plugin/plugin.json
├── skills/<name>/SKILL.md     the thirteen skills
└── model/                     machine.js, pr-machine.js, schema.sql, tests, map page
```

Run the model's tests from `model/` with `node --test`.
