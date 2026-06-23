from __future__ import annotations

import sqlite3
from typing import Any

from .org_render import TODO_BY_STATE, issue_update_url, load_labels, org_clean_title, org_custom_id


def dashboard_issues(conn: sqlite3.Connection, state: str | None = None) -> list[dict[str, Any]]:
    """Return issue rows shaped for the Emacs dashboard."""
    where = ""
    params: list[object] = []
    if state and state != "all":
        where = "WHERE i.state = ?"
        params.append(state)

    rows = conn.execute(
        f"""
        SELECT
            p.path_with_namespace,
            i.project_id,
            i.iid,
            i.title,
            i.state,
            i.updated_at,
            i.assignee_username,
            i.labels_json,
            i.web_url
        FROM issues i
        JOIN projects p ON p.id = i.project_id
        {where}
        ORDER BY
            CASE i.state WHEN 'opened' THEN 0 ELSE 1 END,
            i.updated_at DESC,
            p.path_with_namespace,
            i.iid
        """,
        params,
    ).fetchall()

    issues: list[dict[str, Any]] = []
    for row in rows:
        project = str(row["path_with_namespace"])
        iid = int(row["iid"])
        web_url = row["web_url"] or ""
        issues.append(
            {
                "custom_id": org_custom_id(project, iid),
                "project": project,
                "iid": iid,
                "state": row["state"],
                "todo": TODO_BY_STATE.get(row["state"], "UNKNOWN"),
                "title": org_clean_title(str(row["title"])),
                "assignee": row["assignee_username"] or "",
                "labels": load_labels(row["labels_json"]),
                "updated_at": row["updated_at"] or "",
                "web_url": web_url,
                "updated_url": issue_update_url(conn, int(row["project_id"]), iid, web_url),
            }
        )
    return issues
