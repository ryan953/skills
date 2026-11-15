# pr-board

A Claude Code mod: a pane of your open pull requests, kept beside the chat and
refreshed in the background with your own `gh` login.

`/prs` opens it (`/prs ci:fail` opens it filtered).

## What it shows

PRs are split into **Mine**, **Other people** and **Bots**. Each section folds,
and each PR shows:

- repo, number and title
- CI (`✓` / `✗` / `●` running / `–` none), draft or ready
- review decision, and whether you've approved it already
- conflicts / behind base, automerge, unresolved review threads
- size, author, last update, and labels in their GitHub colors

Click a PR to open its actions:

| Button | Does |
|---|---|
| Open on GitHub | opens the PR in your browser (a link on mobile) |
| Chat | resumes the newest saved Claude conversation that mentions the PR's URL, or ran on its branch in a checkout of that repo. If there isn't one, it starts a new chat in your local clone. Opens in a new tmux window; with no tmux server running, it copies the command instead. |
| Approve | `/approve-pr <url>`: other people's PRs you haven't approved |
| Merge | `/merge-pr <url>`: any PR that isn't a draft |
| getsentry tests | `/getsentry-tests <url>`: getsentry/sentry PRs without the label |
| Hide: 1 day · 1 week · until it changes | snoozes the PR; "until it changes" lifts on the next push, comment, review or label |

A skill button only appears when that skill is installed. The skill runs in the
current session, and the list refreshes when its turn ends. **Hidden (n)** lists
your snoozed PRs, each with an Unhide button. Snoozes last across sessions.

## Filter

Words match the title, repo, branch, author or `#number`. Keys narrow on one
field, a leading `-` negates, and quotes keep spaces:

```
repo:sentry  author:alice  label:"needs review"  branch:feat/
ci:fail | ci:pass | ci:pending    review:approved | review:changes
is:draft | is:ready | is:approved | is:automerge | is:conflicts | is:unreviewed
-is:draft  -label:wip
```

## Settings

In `/config` (or `pluginConfigs.pr-board` in settings):

- **GitHub searches** (`queries`): semicolon-separated PR searches. `is:pr is:open`
  is added for you. Default `author:@me; review-requested:@me`. Add e.g.
  `org:getsentry author:app/dependabot` to see bot PRs nobody asked you to review.
- **Code folders** (`codeRoots`): where your clones live, as `<root>/<repo>` or
  `<root>/<owner>/<repo>`; default `~/code`.
- **Refresh every (minutes)** (`refreshMinutes`): default 5, 0 for off.

## Needs

`gh` signed in. `tmux` for the Chat button.

## Install

```
/plugin install pr-board --marketplace ryan953/skills
```

## Develop

```bash
claude plugin validate plugins/pr-board
claude plugin test plugins/pr-board
claude --plugin-dir plugins/pr-board
```
