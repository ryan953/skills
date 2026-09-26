-- Task list state machine: SQLite storage.
--
-- Mirrors machine.js (tasks) and pr-machine.js (PRs). The rule the models follow
-- holds here too: store real state and facts, derive everything else in views.
--
--   stored   task status; a PR's facts (CI result, comments, accepted, merged, closed)
--   derived  PR status, "is a parent", "has incomplete subtasks", "ready for done"
--
-- Triggers are a safety net for the invariants. The app still runs the machines
-- and decides which event to fire; the database refuses a row that no event
-- could have produced.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- Tasks
-- ---------------------------------------------------------------------------

CREATE TABLE tasks (
  id          INTEGER PRIMARY KEY,
  title       TEXT    NOT NULL CHECK (length(trim(title)) > 0),
  status      TEXT    NOT NULL DEFAULT 'todo'
              CHECK (status IN ('todo', 'in_progress', 'in_review', 'done')),
  -- Set when this task was created by DECOMPOSE on its parent. Being a parent
  -- is not stored: a task is a parent when some row points at it.
  parent_id   INTEGER REFERENCES tasks (id) ON DELETE RESTRICT,
  created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  CHECK (parent_id IS NULL OR parent_id <> id)
);

CREATE INDEX tasks_parent ON tasks (parent_id);
CREATE INDEX tasks_status ON tasks (status);

-- Every status change the task machine allows, including the ones that keep
-- the status (actions such as DECOMPOSE). Kept in step with machine.js by
-- schema.test.js.
CREATE TABLE task_transitions (
  event        TEXT NOT NULL,
  from_status  TEXT,              -- NULL: the task does not exist yet (ENTER)
  to_status    TEXT NOT NULL,
  actor        TEXT NOT NULL CHECK (actor IN ('human', 'pr', 'auto')),
  PRIMARY KEY (event, from_status, to_status)
);

INSERT INTO task_transitions (event, from_status, to_status, actor) VALUES
  ('ENTER',       NULL,          'todo',        'human'),
  ('START',       'todo',        'in_progress', 'human'),
  ('PR_CREATED',  'in_progress', 'in_review',   'pr'),
  ('AUTO_DONE',   'in_review',   'done',        'auto'),
  ('PR_CLOSED',   'in_review',   'in_progress', 'pr'),
  ('PR_CLOSED',   'in_review',   'todo',        'pr'),
  ('COMPLETE',    'in_progress', 'done',        'human'),
  ('DECOMPOSE',   'todo',        'todo',        'human'),
  ('DECOMPOSE',   'in_progress', 'in_progress', 'human'),
  ('DECOMPOSE',   'in_review',   'in_review',   'human'),
  ('PR_CREATED',  'in_review',   'in_review',   'pr'),
  ('PR_CLOSED',   'in_review',   'in_review',   'pr');

-- ---------------------------------------------------------------------------
-- PRs
-- ---------------------------------------------------------------------------

CREATE TABLE prs (
  id          INTEGER PRIMARY KEY,
  -- Where the PR lives. Detection upserts on (repo, number), so re-detecting a
  -- PR updates the row instead of adding a second one.
  repo        TEXT    NOT NULL,
  number      INTEGER NOT NULL CHECK (number > 0),
  url         TEXT,
  title       TEXT    NOT NULL,
  -- Who wrote it decides who takes each action (pr-machine.js `kinds`).
  kind        TEXT    NOT NULL CHECK (kind IN ('mine', 'bot', 'other')),
  author      TEXT,
  -- `task`: created from a task you are working on. `detected`: found by an
  -- external system and inserted for tracking. Only my PRs come from tasks.
  origin      TEXT    NOT NULL CHECK (origin IN ('task', 'detected')),
  task_id     INTEGER REFERENCES tasks (id) ON DELETE RESTRICT,

  -- Facts. The status is derived from these in pr_state.
  head_sha    TEXT,                                   -- NEW_COMMITS changes it
  ci          TEXT    NOT NULL DEFAULT 'pending'
              CHECK (ci IN ('pending', 'passed', 'failed')),
  accepted    INTEGER NOT NULL DEFAULT 0 CHECK (accepted IN (0, 1)),
  merged_at   TEXT,
  closed_at   TEXT,

  created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

  UNIQUE (repo, number),
  CHECK (kind = 'mine' OR origin = 'detected'),
  CHECK (origin = 'detected' OR task_id IS NOT NULL),
  CHECK (merged_at IS NULL OR closed_at IS NULL)
);

CREATE INDEX prs_task ON prs (task_id);

-- Review comments, one row per thread. "Unresolved comments" is the count of
-- rows with resolved_at NULL. COMMENT_ADDED inserts a row; COMMENT_REPLIED
-- sets resolved_at.
CREATE TABLE pr_comments (
  id           INTEGER PRIMARY KEY,
  pr_id        INTEGER NOT NULL REFERENCES prs (id) ON DELETE CASCADE,
  external_id  TEXT,                                  -- thread id upstream, for sync
  author       TEXT,
  created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  resolved_at  TEXT,
  UNIQUE (pr_id, external_id)
);

CREATE INDEX pr_comments_open ON pr_comments (pr_id) WHERE resolved_at IS NULL;

-- ---------------------------------------------------------------------------
-- Event log: append-only history of everything fired, for both machines.
-- ---------------------------------------------------------------------------

CREATE TABLE events (
  id           INTEGER PRIMARY KEY,
  at           TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  task_id      INTEGER REFERENCES tasks (id) ON DELETE CASCADE,
  pr_id        INTEGER REFERENCES prs (id) ON DELETE CASCADE,
  event        TEXT    NOT NULL,          -- ENTER, START, CI_FAILED, DETECTED, ...
  -- human/pr/auto for task events; me/author/bot/reviewer/ci/system for PR events.
  actor        TEXT    NOT NULL CHECK (actor IN ('human', 'pr', 'auto', 'me', 'author', 'bot', 'reviewer', 'ci', 'system')),
  from_status  TEXT,
  to_status    TEXT,
  detail       TEXT CHECK (detail IS NULL OR json_valid(detail)),
  CHECK (task_id IS NOT NULL OR pr_id IS NOT NULL)
);

CREATE INDEX events_task ON events (task_id, at);
CREATE INDEX events_pr ON events (pr_id, at);

-- ---------------------------------------------------------------------------
-- Derived state
-- ---------------------------------------------------------------------------

-- PR status, first match wins: merged, closed, ci_failed, has_feedback,
-- accepted, awaiting_review. Same order as status() in pr-machine.js.
CREATE VIEW pr_state AS
SELECT
  p.*,
  (SELECT count(*) FROM pr_comments c WHERE c.pr_id = p.id AND c.resolved_at IS NULL) AS open_comments,
  CASE
    WHEN p.merged_at IS NOT NULL THEN 'merged'
    WHEN p.closed_at IS NOT NULL THEN 'closed'
    WHEN p.ci = 'failed' THEN 'ci_failed'
    WHEN EXISTS (SELECT 1 FROM pr_comments c WHERE c.pr_id = p.id AND c.resolved_at IS NULL) THEN 'has_feedback'
    WHEN p.accepted = 1 THEN 'accepted'
    ELSE 'awaiting_review'
  END AS status
FROM prs p;

-- Per task: what the done guard reads. Closed PRs are ignored.
CREATE VIEW task_state AS
SELECT
  t.*,
  EXISTS (SELECT 1 FROM tasks c WHERE c.parent_id = t.id) AS is_parent,
  (SELECT count(*) FROM tasks c WHERE c.parent_id = t.id AND c.status <> 'done') AS incomplete_subtasks,
  (SELECT count(*) FROM prs p WHERE p.task_id = t.id AND p.merged_at IS NULL AND p.closed_at IS NULL) AS open_prs,
  (SELECT count(*) FROM prs p WHERE p.task_id = t.id AND p.merged_at IS NOT NULL) AS merged_prs,
  (SELECT count(*) FROM prs p WHERE p.task_id = t.id AND p.closed_at IS NOT NULL) AS closed_prs,
  (NOT EXISTS (SELECT 1 FROM tasks c WHERE c.parent_id = t.id AND c.status <> 'done')
   AND NOT EXISTS (SELECT 1 FROM prs p WHERE p.task_id = t.id AND p.merged_at IS NULL AND p.closed_at IS NULL))
    AS ready_for_done
FROM tasks t;

-- Tasks the app should move to done now (settle() in machine.js): in review,
-- with every linked PR merged and every subtask done.
CREATE VIEW tasks_to_auto_complete AS
SELECT id FROM task_state WHERE status = 'in_review' AND ready_for_done;

-- ---------------------------------------------------------------------------
-- Invariants
-- ---------------------------------------------------------------------------

-- New tasks start in todo, including subtasks created by DECOMPOSE.
CREATE TRIGGER tasks_start_in_todo
BEFORE INSERT ON tasks
WHEN NEW.status <> 'todo'
BEGIN
  SELECT RAISE(ABORT, 'new tasks start in todo');
END;

-- A done task can't gain subtasks.
CREATE TRIGGER no_subtasks_on_done
BEFORE INSERT ON tasks
WHEN NEW.parent_id IS NOT NULL
  AND (SELECT status FROM tasks WHERE id = NEW.parent_id) = 'done'
BEGIN
  SELECT RAISE(ABORT, 'a done task cannot be decomposed');
END;

-- A status change must be one the machine allows.
CREATE TRIGGER task_status_allowed
BEFORE UPDATE OF status ON tasks
WHEN NEW.status <> OLD.status
  AND NOT EXISTS (
    SELECT 1 FROM task_transitions
    WHERE from_status = OLD.status AND to_status = NEW.status
  )
BEGIN
  SELECT RAISE(ABORT, 'status change not allowed by the task machine');
END;

-- Done needs every linked PR merged (closed ones ignored) and every subtask done.
CREATE TRIGGER task_done_needs_ready
BEFORE UPDATE OF status ON tasks
WHEN NEW.status = 'done' AND OLD.status <> 'done'
  AND (
    EXISTS (SELECT 1 FROM tasks c WHERE c.parent_id = NEW.id AND c.status <> 'done')
    OR EXISTS (SELECT 1 FROM prs p WHERE p.task_id = NEW.id AND p.merged_at IS NULL AND p.closed_at IS NULL)
  )
BEGIN
  SELECT RAISE(ABORT, 'task has open PRs or incomplete subtasks');
END;

CREATE TRIGGER tasks_touch
AFTER UPDATE ON tasks
WHEN NEW.updated_at = OLD.updated_at
BEGIN
  UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = NEW.id;
END;

-- A PR created from a task must belong to a task that has started. Linking a
-- PR to a done task is refused.
CREATE TRIGGER pr_task_active
BEFORE INSERT ON prs
WHEN NEW.task_id IS NOT NULL
  AND (SELECT status FROM tasks WHERE id = NEW.task_id) NOT IN ('in_progress', 'in_review')
BEGIN
  SELECT RAISE(ABORT, 'PRs are created from tasks in progress or in review');
END;

-- New PRs start fresh: CI pending, not accepted, open. That is awaiting_review.
CREATE TRIGGER prs_start_fresh
BEFORE INSERT ON prs
WHEN NEW.ci <> 'pending' OR NEW.accepted <> 0 OR NEW.merged_at IS NOT NULL OR NEW.closed_at IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'new PRs start awaiting review');
END;

-- Merged and closed are final.
CREATE TRIGGER prs_final
BEFORE UPDATE ON prs
WHEN (OLD.merged_at IS NOT NULL OR OLD.closed_at IS NOT NULL)
  AND (NEW.ci IS NOT OLD.ci OR NEW.accepted IS NOT OLD.accepted OR NEW.head_sha IS NOT OLD.head_sha
       OR NEW.merged_at IS NOT OLD.merged_at OR NEW.closed_at IS NOT OLD.closed_at
       OR NEW.task_id IS NOT OLD.task_id)
BEGIN
  SELECT RAISE(ABORT, 'merged and closed PRs are final');
END;

-- CI results only arrive while a run is pending; new commits start a new run.
CREATE TRIGGER prs_ci_result_needs_run
BEFORE UPDATE OF ci ON prs
WHEN NEW.ci IN ('passed', 'failed') AND OLD.ci <> 'pending'
BEGIN
  SELECT RAISE(ABORT, 'CI results only arrive while a run is pending');
END;

-- Only an accepted PR can merge.
CREATE TRIGGER prs_merge_needs_accepted
BEFORE UPDATE OF merged_at ON prs
WHEN NEW.merged_at IS NOT NULL AND OLD.merged_at IS NULL
  AND (SELECT status FROM pr_state WHERE id = OLD.id) <> 'accepted'
BEGIN
  SELECT RAISE(ABORT, 'only an accepted PR can merge');
END;

CREATE TRIGGER prs_touch
AFTER UPDATE ON prs
WHEN NEW.updated_at = OLD.updated_at
BEGIN
  UPDATE prs SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = NEW.id;
END;

-- No new comments or replies on a merged or closed PR.
CREATE TRIGGER comments_on_open_pr
BEFORE INSERT ON pr_comments
WHEN (SELECT merged_at IS NOT NULL OR closed_at IS NOT NULL FROM prs WHERE id = NEW.pr_id)
BEGIN
  SELECT RAISE(ABORT, 'merged and closed PRs are final');
END;

CREATE TRIGGER comment_replies_on_open_pr
BEFORE UPDATE OF resolved_at ON pr_comments
WHEN (SELECT merged_at IS NOT NULL OR closed_at IS NOT NULL FROM prs WHERE id = NEW.pr_id)
BEGIN
  SELECT RAISE(ABORT, 'merged and closed PRs are final');
END;
