#!/usr/bin/env python3
"""Drive Seer autofix over a set of Sentry issues without spending inference per issue.

Fetches an issue list from the Sentry API, then for each issue either reports its
current autofix state or triggers a run. Triggering with --run-to open_pr drives the
whole pipeline (root_cause -> solution -> code_changes -> open_pr) server-side.

Uses only the Python stdlib so it runs under the repo .venv with no extra deps.

Auth: pass a Sentry auth token via --token or the SENTRY_AUTH_TOKEN env var. Create
one at https://sentry.io/settings/account/api/auth-tokens/ with `event:read` and
`event:write` scopes (write is needed to trigger autofix).

Examples:
    # List issues + their autofix status, no mutations (safe default).
    python autofix_sweep.py --org sentry --project 4511567035432960 \\
        --query 'is:unresolved [static-component-definitions]' --stats-period 30d

    # Trigger autofix to PR on every issue that has not started yet.
    python autofix_sweep.py --org sentry --project 4511567035432960 \\
        --query 'is:unresolved [static-component-definitions]' \\
        --run-to open_pr --only-unstarted

    # Drive a single issue by short id.
    python autofix_sweep.py --org sentry --issues CODING-CONVENTIONS-36Z --run-to open_pr
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_HOST = "https://sentry.io"
# Steps the autofix pipeline moves through, in order. Used to pick a stopping point
# and to render progress.
STEP_ORDER = ["root_cause", "solution", "code_changes", "open_pr"]
# Terminal autofix statuses (lowercased) at which polling should stop.
TERMINAL_STATUSES = {"completed", "error", "cancelled", "need_more_information"}


class SentryClient:
    def __init__(self, token: str, host: str = DEFAULT_HOST) -> None:
        self.token = token
        self.host = host.rstrip("/")

    def _request(self, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        url = f"{self.host}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read().decode()
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            try:
                parsed = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                parsed = {"detail": raw}
            return e.code, parsed

    def list_issues(
        self,
        org: str,
        query: str,
        project: str | None,
        stats_period: str,
        sort: str,
        limit: int,
    ) -> list[dict]:
        """Page through the org issues endpoint until limit or exhaustion."""
        params = {
            "query": query,
            "statsPeriod": stats_period,
            "sort": sort,
            "limit": str(min(limit, 100)),
        }
        if project:
            params["project"] = project
        issues: list[dict] = []
        path = f"/api/0/organizations/{org}/issues/?{urllib.parse.urlencode(params)}"
        while path and len(issues) < limit:
            status, payload = self._request("GET", path)
            if status != 200:
                raise RuntimeError(f"list_issues failed ({status}): {payload}")
            issues.extend(payload if isinstance(payload, list) else [])
            path = None  # Pagination via Link headers is omitted; one page covers our case.
        return issues[:limit]

    def get_autofix_state(self, issue_id: str) -> dict | None:
        status, payload = self._request("GET", f"/api/0/issues/{issue_id}/autofix/")
        if status != 200:
            raise RuntimeError(f"get_autofix_state failed ({status}): {payload}")
        return payload.get("autofix")

    def trigger_autofix(self, issue_id: str, stopping_point: str) -> tuple[int, dict]:
        return self._request(
            "POST",
            f"/api/0/issues/{issue_id}/autofix/",
            {"stopping_point": stopping_point, "referrer": "autofix_issue_sweep"},
        )


def summarize_state(state: dict | None) -> str:
    if not state:
        return "no run"
    status = str(state.get("status", "unknown")).lower()
    pr = extract_pr_url(state)
    if pr:
        return f"{status} · PR {pr}"
    return status


def extract_pr_url(state: dict | None) -> str | None:
    if not state:
        return None
    for pr_state in (state.get("repo_pr_states") or {}).values():
        url = pr_state.get("pr_url") or pr_state.get("url")
        if url:
            return url
    return None


def poll_until_terminal(
    client: SentryClient, issue_id: str, timeout: int, interval: int
) -> dict | None:
    deadline = time.time() + timeout
    state = client.get_autofix_state(issue_id)
    while time.time() < deadline:
        status = str((state or {}).get("status", "")).lower()
        if status in TERMINAL_STATUSES or extract_pr_url(state):
            return state
        time.sleep(interval)
        state = client.get_autofix_state(issue_id)
    return state


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--org", required=True, help="Organization slug, e.g. sentry")
    parser.add_argument("--project", help="Numeric project id to scope the issue search")
    parser.add_argument("--query", help="Sentry issue search query")
    parser.add_argument(
        "--issues", nargs="*", default=[], help="Explicit issue short ids (skips search)"
    )
    parser.add_argument(
        "--stats-period", default="30d", help="statsPeriod for the search (default 30d)"
    )
    parser.add_argument("--sort", default="date", help="Sort order for search (default date)")
    parser.add_argument("--limit", type=int, default=100, help="Max issues to process")
    parser.add_argument("--host", default=os.environ.get("SENTRY_HOST", DEFAULT_HOST))
    parser.add_argument("--token", default=os.environ.get("SENTRY_AUTH_TOKEN"))
    parser.add_argument(
        "--run-to",
        choices=STEP_ORDER,
        help="Trigger autofix up to this step. Omit to only report current state (dry run).",
    )
    parser.add_argument(
        "--only-unstarted",
        action="store_true",
        help="With --run-to, skip issues that already have an autofix run.",
    )
    parser.add_argument(
        "--poll", action="store_true", help="After triggering, poll each run to completion"
    )
    parser.add_argument(
        "--poll-timeout", type=int, default=600, help="Per-issue poll timeout seconds"
    )
    parser.add_argument("--poll-interval", type=int, default=20, help="Poll interval seconds")
    parser.add_argument("--json", action="store_true", help="Emit results as JSON")
    args = parser.parse_args()

    if not args.token:
        print("ERROR: no auth token. Pass --token or set SENTRY_AUTH_TOKEN.", file=sys.stderr)
        return 2
    if not args.issues and not args.query:
        print("ERROR: provide --query or --issues.", file=sys.stderr)
        return 2

    client = SentryClient(args.token, args.host)

    if args.issues:
        issues = [{"shortId": s, "title": s} for s in args.issues]
    else:
        raw = client.list_issues(
            args.org, args.query, args.project, args.stats_period, args.sort, args.limit
        )
        issues = [{"shortId": i.get("shortId"), "title": i.get("title", "")} for i in raw]

    if not issues:
        print("No issues matched.")
        return 0

    results = []
    for idx, issue in enumerate(issues, 1):
        short_id = issue["shortId"]
        title = (issue.get("title") or "").splitlines()[0][:80]
        try:
            state = client.get_autofix_state(short_id)
        except RuntimeError as e:
            results.append({"issue": short_id, "action": "error", "detail": str(e)})
            print(f"[{idx}/{len(issues)}] {short_id}  ERROR reading state: {e}")
            continue

        already_started = bool(state)
        action = "reported"
        if args.run_to:
            if args.only_unstarted and already_started:
                action = "skipped (already started)"
            else:
                code, payload = client.trigger_autofix(short_id, args.run_to)
                if code == 202:
                    action = f"triggered -> {args.run_to}"
                    if args.poll:
                        state = poll_until_terminal(
                            client, short_id, args.poll_timeout, args.poll_interval
                        )
                else:
                    action = f"trigger failed ({code}): {payload.get('detail', payload)}"

        pr = extract_pr_url(state)
        results.append(
            {
                "issue": short_id,
                "title": title,
                "action": action,
                "status": summarize_state(state),
                "pr": pr,
            }
        )
        print(f"[{idx}/{len(issues)}] {short_id}  {action}  | {summarize_state(state)}")

    if args.json:
        print(json.dumps(results, indent=2))

    triggered = sum(1 for r in results if str(r["action"]).startswith("triggered"))
    prs = [r["pr"] for r in results if r.get("pr")]
    print(f"\nDone. {len(results)} issues · {triggered} triggered · {len(prs)} with PRs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
