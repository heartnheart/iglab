from __future__ import annotations

import json
import re
import sqlite3
import unicodedata


TODO_BY_STATE = {
    "opened": "TODO",
    "closed": "CLOSED",
}

ORG_FILE_LOCAL_VARIABLES = "# -*- eval: (visual-fill-column-mode -1); eval: (display-line-numbers-mode -1); -*-"
ORG_HEADING_RE = re.compile(r"^(\*+)\s+")
ORG_CUSTOM_ID_RE = re.compile(r"^:CUSTOM_ID:\s+(.+?)\s*$")


def render_org(conn: sqlite3.Connection, existing_org: str | None = None) -> str:
    preserved_bodies = parse_preserved_issue_bodies(existing_org)
    lines: list[str] = [
        ORG_FILE_LOCAL_VARIABLES,
        "#+TITLE: GitLab Issues",
        "#+TODO: TODO DOING BLOCKED REVIEW UNKNOWN | DONE CLOSED",
        "",
        "* Dashboard",
        ":PROPERTIES:",
        ":IGLAB_AUTOGEN: t",
        ":END:",
        "",
        "** Unknown Status",
        "",
        "* Issues",
    ]

    rows = conn.execute(
        """
        SELECT
            p.path_with_namespace,
            i.project_id,
            i.iid,
            i.title,
            i.state,
            i.created_at,
            i.updated_at,
            i.assignee_username,
            i.labels_json,
            i.web_url
        FROM issues i
        JOIN projects p ON p.id = i.project_id
        ORDER BY p.path_with_namespace, i.iid
        """
    ).fetchall()

    current_project: str | None = None
    for row in rows:
        project = row["path_with_namespace"]
        if project != current_project:
            lines.append(f"** {org_clean_heading(project)}")
            current_project = project

        todo = TODO_BY_STATE.get(row["state"], "UNKNOWN")
        custom_id = org_custom_id(project, row["iid"])
        title = org_clean_title(str(row["title"]))
        tags = org_tags(load_labels(row["labels_json"]))
        tag_suffix = f" {tags}" if tags else ""
        update_url = issue_update_url(conn, int(row["project_id"]), int(row["iid"]), row["web_url"])
        created_at = org_property_value(row["created_at"] or "")
        updated_at = org_property_value(row["updated_at"] or "")
        lines.extend(
            [
                f"*** {todo} #{row['iid']} {title}{tag_suffix}",
                ":PROPERTIES:",
                f":CUSTOM_ID: {custom_id}",
                f":GITLAB_PROJECT: {org_property_value(project)}",
                f":GITLAB_IID: {row['iid']}",
                f":GITLAB_LABELS: {org_property_value(','.join(load_labels(row['labels_json'])))}",
                f":GITLAB_CREATED_AT: {created_at}",
                f":GITLAB_UPDATED_AT: {updated_at}",
                f":GTLAB_UPDATED_URL: {org_property_value(update_url)}",
                f":GITLAB_WEB_URL: {org_property_value(row['web_url'] or '')}",
                f":GITLAB_ASSIGNEE: {org_property_value(row['assignee_username'] or '')}",
                ":IGLAB_AUTOGEN: t",
                ":END:",
                "",
            ]
        )
        if preserved_body := preserved_bodies.get(custom_id):
            lines.extend(preserved_body.splitlines())
            lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def parse_preserved_issue_bodies(existing_org: str | None) -> dict[str, str]:
    if not existing_org:
        return {}

    bodies: dict[str, str] = {}
    lines = existing_org.splitlines()
    index = 0
    while index < len(lines):
        heading = ORG_HEADING_RE.match(lines[index])
        if heading is None or len(heading.group(1)) != 3:
            index += 1
            continue

        block_end = index + 1
        while block_end < len(lines):
            next_heading = ORG_HEADING_RE.match(lines[block_end])
            if next_heading is not None and len(next_heading.group(1)) <= 3:
                break
            block_end += 1

        custom_id, body = parse_issue_block(lines[index:block_end])
        if custom_id is not None and body:
            bodies[custom_id] = body
        index = block_end

    return bodies


def parse_issue_block(lines: list[str]) -> tuple[str | None, str]:
    custom_id: str | None = None
    properties_start: int | None = None
    properties_end: int | None = None

    for index, line in enumerate(lines[1:], start=1):
        if line == ":PROPERTIES:":
            properties_start = index
        elif properties_start is not None and line == ":END:":
            properties_end = index
            break
        elif properties_start is not None:
            match = ORG_CUSTOM_ID_RE.match(line)
            if match is not None:
                custom_id = match.group(1)

    if custom_id is None or properties_end is None:
        return None, ""

    body_lines = strip_blank_edges(lines[properties_end + 1 :])
    legacy_notes = extract_legacy_local_notes(body_lines)
    if legacy_notes is not None:
        body_lines = legacy_notes
    return custom_id, "\n".join(strip_blank_edges(body_lines))


def extract_legacy_local_notes(lines: list[str]) -> list[str] | None:
    for index, line in enumerate(lines):
        if line == ":LOCAL_NOTES:":
            end = index + 1
            while end < len(lines) and lines[end] != ":END:":
                end += 1
            if end < len(lines):
                return strip_blank_edges(lines[index + 1 : end])
    return None


def strip_blank_edges(lines: list[str]) -> list[str]:
    start = 0
    end = len(lines)
    while start < end and lines[start] == "":
        start += 1
    while end > start and lines[end - 1] == "":
        end -= 1
    return lines[start:end]


def org_clean_heading(value: str) -> str:
    return " ".join(value.replace("\r", " ").replace("\n", " ").split())


def org_clean_title(value: str) -> str:
    return org_clean_heading(value).replace("【", "[").replace("】", "]")


def org_property_value(value: str) -> str:
    return value.replace("\r", " ").replace("\n", "\\n")


def issue_update_url(conn: sqlite3.Connection, project_id: int, issue_iid: int, web_url: str | None) -> str:
    row = conn.execute(
        """
        SELECT note_id
        FROM issue_activity_notes
        WHERE project_id = ? AND issue_iid = ?
        ORDER BY created_at DESC, note_id DESC
        LIMIT 1
        """,
        (project_id, issue_iid),
    ).fetchone()
    if row is None or not web_url:
        return web_url or ""
    return f"{web_url}#note_{row['note_id']}"


def load_labels(value: str | None) -> list[str]:
    if not value:
        return []
    try:
        labels = json.loads(value)
    except json.JSONDecodeError:
        return []
    if not isinstance(labels, list):
        return []
    return [str(label) for label in labels]


def org_tags(labels: list[str]) -> str:
    tags = []
    seen = set()
    for label in labels:
        tag = org_tag_name(label)
        if tag and tag not in seen:
            tags.append(tag)
            seen.add(tag)
    if not tags:
        return ""
    return ":" + ":".join(tags) + ":"


def org_tag_name(label: str) -> str:
    normalized = unicodedata.normalize("NFKC", label).strip()
    chars = []
    for char in normalized:
        if char.isalnum() or char == "_":
            chars.append(char)
        elif char in ("-", "/", ":", ".", " "):
            chars.append("_")
    tag = "".join(chars).strip("_")
    while "__" in tag:
        tag = tag.replace("__", "_")
    return tag


def org_custom_id(project_path: str, iid: int) -> str:
    safe = []
    for char in project_path.lower():
        if char.isalnum():
            safe.append(char)
        else:
            safe.append("-")
    return f"gitlab-{' '.join(''.join(safe).split()).replace(' ', '-')}-{iid}"
