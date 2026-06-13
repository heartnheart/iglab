from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass


ASSIGNED_TO_RE = re.compile(r"\bassigned to @(?P<new>[A-Za-z0-9_.-]+)")
UNASSIGNED_RE = re.compile(r"\bunassigned @(?P<old>[A-Za-z0-9_.-]+)")


@dataclass(frozen=True)
class AssigneeEvent:
    project: str
    issue_iid: int
    occurred_at: str
    actor_username: str | None
    old_assignee_username: str | None
    new_assignee_username: str | None
    source: str
    source_id: str
    quality: str
    raw_body: str

    def to_dict(self) -> dict[str, object]:
        return {
            "project": self.project,
            "issue_iid": self.issue_iid,
            "occurred_at": self.occurred_at,
            "actor_username": self.actor_username,
            "old_assignee_username": self.old_assignee_username,
            "new_assignee_username": self.new_assignee_username,
            "source": self.source,
            "source_id": self.source_id,
            "quality": self.quality,
            "raw_body": self.raw_body,
        }


@dataclass(frozen=True)
class AssignedIssue:
    project: str
    issue_iid: int
    title: str
    assigned_at: str | None
    web_url: str | None

    def to_dict(self) -> dict[str, object]:
        return {
            "project": self.project,
            "issue_iid": self.issue_iid,
            "title": self.title,
            "assigned_at": self.assigned_at,
            "web_url": self.web_url,
        }


def parse_assignee_note(project: str, issue_iid: int, note: sqlite3.Row) -> AssigneeEvent | None:
    body = str(note["body"])
    new_match = ASSIGNED_TO_RE.search(body)
    old_match = UNASSIGNED_RE.search(body)
    if not new_match and not old_match:
        return None

    return AssigneeEvent(
        project=project,
        issue_iid=issue_iid,
        occurred_at=str(note["created_at"]),
        actor_username=note["author_username"],
        old_assignee_username=old_match.group("old") if old_match else None,
        new_assignee_username=new_match.group("new") if new_match else None,
        source="system_note",
        source_id=str(note["note_id"]),
        quality="parsed",
        raw_body=body,
    )


def parse_assignee_events_for_issue(conn: sqlite3.Connection, project: str, issue_iid: int) -> list[AssigneeEvent]:
    rows = conn.execute(
        """
        SELECT n.*
        FROM issue_activity_notes n
        JOIN projects p ON p.id = n.project_id
        WHERE p.path_with_namespace = ?
          AND n.issue_iid = ?
          AND n.system = 1
        ORDER BY n.created_at, n.note_id
        """,
        (project, issue_iid),
    ).fetchall()

    events = []
    for row in rows:
        event = parse_assignee_note(project, issue_iid, row)
        if event is not None:
            events.append(event)
    return events


def assignee_at(conn: sqlite3.Connection, username: str, timestamp: str) -> list[AssignedIssue]:
    issues = conn.execute(
        """
        SELECT p.path_with_namespace, i.project_id, i.iid, i.title, i.web_url
        FROM issues i
        JOIN projects p ON p.id = i.project_id
        WHERE i.created_at IS NULL OR i.created_at <= ?
        ORDER BY p.path_with_namespace, i.iid
        """,
        (timestamp,),
    ).fetchall()

    matches: list[AssignedIssue] = []
    for issue in issues:
        project = issue["path_with_namespace"]
        events = parse_assignee_events_for_issue(conn, project, int(issue["iid"]))
        current: str | None = None
        assigned_at: str | None = None
        for event in events:
            if event.occurred_at > timestamp:
                break
            if event.old_assignee_username == current:
                current = None
                assigned_at = None
            if event.new_assignee_username is not None:
                current = event.new_assignee_username
                assigned_at = event.occurred_at
        if current == username:
            matches.append(
                AssignedIssue(
                    project=project,
                    issue_iid=int(issue["iid"]),
                    title=str(issue["title"]),
                    assigned_at=assigned_at,
                    web_url=issue["web_url"],
                )
            )
    return matches
