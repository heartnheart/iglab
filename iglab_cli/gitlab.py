from __future__ import annotations

import json
import sqlite3
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Iterable

from .config import Config


@dataclass(frozen=True)
class GitLabClient:
    config: Config

    def require_configured(self) -> None:
        if not self.config.gitlab_host:
            raise ValueError("gitlab_host is not configured")
        if not self.config.gitlab_token:
            raise ValueError("gitlab_token is not configured")

    def sync_active(self, conn: sqlite3.Connection, progress: Callable[[str], None] | None = None) -> None:
        self.require_configured()
        progress = progress or (lambda _message: None)
        now = _now_iso()
        project_count = 0
        issue_count = 0
        note_count = 0
        for project in self.iter_projects():
            if not self._project_allowed(project):
                continue
            project_count += 1
            project_path = str(project.get("path_with_namespace", project.get("id")))
            progress(f"project {project_count}: {project_path}")
            upsert_project(conn, project, now)
            issues = list(self.iter_active_issues(int(project["id"])))
            progress(f"  active issues: {len(issues)}")
            for index, issue in enumerate(issues, start=1):
                issue_count += 1
                needs_notes = issue_needs_note_sync(conn, int(project["id"]), issue)
                upsert_issue(conn, int(project["id"]), issue, now)
                if needs_notes:
                    issue_note_count = 0
                    for note in self.iter_issue_activity_notes(int(project["id"]), int(issue["iid"])):
                        note_count += 1
                        issue_note_count += 1
                        upsert_activity_note(conn, int(project["id"]), int(issue["iid"]), note)
                    mark_issue_notes_synced(conn, int(project["id"]), int(issue["iid"]), now)
                    if issue_note_count:
                        progress(f"  issue #{issue['iid']}: synced {issue_note_count} activity notes")
                if index == len(issues) or index % 10 == 0:
                    progress(f"  notes synced for {index}/{len(issues)} issues")
            conn.commit()
        progress(f"done: projects={project_count} issues={issue_count} activity_notes={note_count}")

    def iter_projects(self) -> Iterable[dict[str, Any]]:
        seen: set[int] = set()
        for group in self.config.root_groups:
            quoted_group = urllib.parse.quote(group, safe="")
            path = f"/api/v4/groups/{quoted_group}/projects"
            params = {
                "include_subgroups": "true",
                "with_issues_enabled": "true",
                "archived": "false",
                "simple": "true",
                "per_page": "100",
            }
            for project in self._get_paginated(path, params):
                project_id = int(project["id"])
                if project_id not in seen:
                    seen.add(project_id)
                    yield project
        for project_path in self.config.project_paths:
            quoted_project = urllib.parse.quote(project_path, safe="")
            project, _headers = self._get_json(f"/api/v4/projects/{quoted_project}", {})
            if not isinstance(project, dict):
                raise ValueError(f"Expected project response for {project_path}")
            project_id = int(project["id"])
            if project_id not in seen:
                seen.add(project_id)
                yield project

    def iter_active_issues(self, project_id: int) -> Iterable[dict[str, Any]]:
        seen: set[int] = set()
        for issue in self._iter_project_issues(project_id, {"state": "opened"}):
            seen.add(int(issue["iid"]))
            yield issue

        updated_after = datetime.now(timezone.utc) - timedelta(days=self.config.closed_lookback_days)
        for issue in self._iter_project_issues(
            project_id,
            {
                "state": "closed",
                "updated_after": updated_after.isoformat().replace("+00:00", "Z"),
            },
        ):
            issue_iid = int(issue["iid"])
            if issue_iid not in seen:
                yield issue

    def iter_issue_activity_notes(self, project_id: int, issue_iid: int) -> Iterable[dict[str, Any]]:
        path = f"/api/v4/projects/{project_id}/issues/{issue_iid}/notes"
        params = {
            "activity_filter": "only_activity",
            "sort": "asc",
            "order_by": "created_at",
            "per_page": "100",
        }
        yield from self._get_paginated(path, params)

    def _iter_project_issues(self, project_id: int, params: dict[str, str]) -> Iterable[dict[str, Any]]:
        path = f"/api/v4/projects/{project_id}/issues"
        merged = {
            "scope": "all",
            "per_page": "100",
        }
        merged.update(params)
        yield from self._get_paginated(path, merged)

    def _project_allowed(self, project: dict[str, Any]) -> bool:
        path = str(project.get("path_with_namespace", ""))
        if self.config.include_path_regexp:
            import re

            if not re.search(self.config.include_path_regexp, path):
                return False
        if self.config.exclude_path_regexp:
            import re

            if re.search(self.config.exclude_path_regexp, path):
                return False
        return True

    def _get_paginated(self, path: str, params: dict[str, str]) -> Iterable[dict[str, Any]]:
        page = 1
        while True:
            page_params = dict(params)
            page_params["page"] = str(page)
            result, headers = self._get_json(path, page_params)
            if not isinstance(result, list):
                raise ValueError(f"Expected list response for {path}")
            yield from result
            next_page = headers.get("X-Next-Page") or headers.get("x-next-page")
            if not next_page:
                break
            page = int(next_page)

    def _get_json(self, path: str, params: dict[str, str]) -> tuple[Any, dict[str, str]]:
        host = str(self.config.gitlab_host).rstrip("/")
        query = urllib.parse.urlencode(params)
        url = f"{host}{path}"
        if query:
            url = f"{url}?{query}"

        request = urllib.request.Request(
            url,
            headers={
                "PRIVATE-TOKEN": str(self.config.gitlab_token),
                "Accept": "application/json",
                "User-Agent": "iglab/0.1",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode("utf-8")
                return json.loads(body), dict(response.headers.items())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GitLab API request failed: {exc.code} {url}\n{detail}") from exc


def upsert_project(conn: sqlite3.Connection, project: dict[str, Any], seen_at: str) -> None:
    conn.execute(
        """
        INSERT INTO projects(id, path_with_namespace, web_url, archived, raw_json, last_seen_at)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            path_with_namespace = excluded.path_with_namespace,
            web_url = excluded.web_url,
            archived = excluded.archived,
            raw_json = excluded.raw_json,
            last_seen_at = excluded.last_seen_at
        """,
        (
            int(project["id"]),
            str(project.get("path_with_namespace", "")),
            project.get("web_url"),
            1 if project.get("archived") else 0,
            _json(project),
            seen_at,
        ),
    )


def upsert_issue(conn: sqlite3.Connection, project_id: int, issue: dict[str, Any], seen_at: str) -> None:
    assignee = issue.get("assignee")
    assignee_username = None
    if isinstance(assignee, dict):
        assignee_username = assignee.get("username")
    elif isinstance(issue.get("assignees"), list) and issue["assignees"]:
        assignee_username = issue["assignees"][0].get("username")

    conn.execute(
        """
        INSERT INTO issues(
            project_id, iid, title, state, created_at, updated_at, closed_at,
            assignee_username, labels_json, web_url, raw_json, last_seen_at
        )
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(project_id, iid) DO UPDATE SET
            title = excluded.title,
            state = excluded.state,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            closed_at = excluded.closed_at,
            assignee_username = excluded.assignee_username,
            labels_json = excluded.labels_json,
            web_url = excluded.web_url,
            raw_json = excluded.raw_json,
            last_seen_at = excluded.last_seen_at
        """,
        (
            project_id,
            int(issue["iid"]),
            str(issue.get("title", "")),
            str(issue.get("state", "")),
            issue.get("created_at"),
            issue.get("updated_at"),
            issue.get("closed_at"),
            assignee_username,
            _json_list(issue.get("labels", [])),
            issue.get("web_url"),
            _json(issue),
            seen_at,
        ),
    )


def issue_needs_note_sync(conn: sqlite3.Connection, project_id: int, issue: dict[str, Any]) -> bool:
    row = conn.execute(
        """
        SELECT i.updated_at, s.last_synced_at
        FROM issues i
        LEFT JOIN issue_note_sync_state s
          ON s.project_id = i.project_id AND s.issue_iid = i.iid
        WHERE i.project_id = ? AND i.iid = ?
        """,
        (project_id, int(issue["iid"])),
    ).fetchone()
    if row is None:
        return True
    if row["last_synced_at"] is None:
        return True
    return str(row["updated_at"] or "") != str(issue.get("updated_at") or "")


def mark_issue_notes_synced(conn: sqlite3.Connection, project_id: int, issue_iid: int, synced_at: str) -> None:
    conn.execute(
        """
        INSERT INTO issue_note_sync_state(
            project_id, issue_iid, backfill_status, last_synced_at, updated_at
        )
        VALUES(?, ?, 'done', ?, ?)
        ON CONFLICT(project_id, issue_iid) DO UPDATE SET
            backfill_status = 'done',
            last_synced_at = excluded.last_synced_at,
            last_error = NULL,
            updated_at = excluded.updated_at
        """,
        (project_id, issue_iid, synced_at, synced_at),
    )


def upsert_activity_note(conn: sqlite3.Connection, project_id: int, issue_iid: int, note: dict[str, Any]) -> None:
    author = note.get("author")
    author_username = author.get("username") if isinstance(author, dict) else None
    conn.execute(
        """
        INSERT INTO issue_activity_notes(
            project_id, issue_iid, note_id, created_at, updated_at,
            author_username, system, body, raw_json
        )
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(project_id, issue_iid, note_id) DO UPDATE SET
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            author_username = excluded.author_username,
            system = excluded.system,
            body = excluded.body,
            raw_json = excluded.raw_json
        """,
        (
            project_id,
            issue_iid,
            int(note["id"]),
            str(note.get("created_at")),
            note.get("updated_at"),
            author_username,
            1 if note.get("system") else 0,
            str(note.get("body", "")),
            _json(note),
        ),
    )


def _json(value: dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def _json_list(value: Any) -> str:
    if not isinstance(value, list):
        value = []
    return json.dumps(value, ensure_ascii=False)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
