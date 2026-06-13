from __future__ import annotations

import json
import sqlite3
import unittest

from iglab_cli.assignee import assignee_at, parse_assignee_events_for_issue
from iglab_cli.db import initialize_database


class AssigneeParserTest(unittest.TestCase):
    def setUp(self) -> None:
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        initialize_database(self.conn)
        self.conn.execute(
            """
            INSERT INTO projects(id, path_with_namespace, web_url, raw_json, last_seen_at)
            VALUES(1, 'project/windows-bug', 'https://gitlab.local/project/windows-bug', '{}', '2026-06-13T00:00:00Z')
            """
        )
        self.conn.execute(
            """
            INSERT INTO issues(project_id, iid, title, state, created_at, updated_at, raw_json, last_seen_at)
            VALUES(1, 340, 'Bug [login]', 'opened', '2026-06-01T00:00:00Z', '2026-06-07T00:00:00Z', '{}', '2026-06-13T00:00:00Z')
            """
        )

    def tearDown(self) -> None:
        self.conn.close()

    def insert_note(self, note_id: int, created_at: str, body: str) -> None:
        self.conn.execute(
            """
            INSERT INTO issue_activity_notes(
                project_id, issue_iid, note_id, created_at, updated_at,
                author_username, system, body, raw_json
            )
            VALUES(1, 340, ?, ?, ?, 'pinghuang', 1, ?, ?)
            """,
            (note_id, created_at, created_at, body, json.dumps({"body": body})),
        )

    def test_parse_reassign_note(self) -> None:
        self.insert_note(751087, "2026-06-07T10:31:00+08:00", "assigned to @zhangli and unassigned @huangping")

        events = parse_assignee_events_for_issue(self.conn, "project/windows-bug", 340)

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].old_assignee_username, "huangping")
        self.assertEqual(events[0].new_assignee_username, "zhangli")
        self.assertEqual(events[0].quality, "parsed")

    def test_assignee_at_replays_events(self) -> None:
        self.insert_note(1, "2026-06-02T10:00:00+08:00", "assigned to @huangping")
        self.insert_note(2, "2026-06-07T10:31:00+08:00", "assigned to @zhangli and unassigned @huangping")

        before = assignee_at(self.conn, "huangping", "2026-06-03T00:00:00+08:00")
        after = assignee_at(self.conn, "zhangli", "2026-06-08T00:00:00+08:00")

        self.assertEqual(len(before), 1)
        self.assertEqual(before[0].issue_iid, 340)
        self.assertEqual(len(after), 1)
        self.assertEqual(after[0].issue_iid, 340)


if __name__ == "__main__":
    unittest.main()
