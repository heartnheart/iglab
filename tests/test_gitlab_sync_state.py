from __future__ import annotations

import sqlite3
import unittest

from iglab_cli.db import initialize_database
from iglab_cli.gitlab import issue_needs_note_sync, mark_issue_notes_synced, upsert_issue


class GitLabSyncStateTest(unittest.TestCase):
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

    def tearDown(self) -> None:
        self.conn.close()

    def test_new_issue_needs_note_sync(self) -> None:
        self.assertTrue(issue_needs_note_sync(self.conn, 1, self.issue("2026-06-07T00:00:00Z")))

    def test_unchanged_issue_skips_note_sync_after_mark(self) -> None:
        issue = self.issue("2026-06-07T00:00:00Z")
        upsert_issue(self.conn, 1, issue, "2026-06-13T00:00:00Z")
        mark_issue_notes_synced(self.conn, 1, 340, "2026-06-13T00:00:00Z")

        self.assertFalse(issue_needs_note_sync(self.conn, 1, issue))

    def test_changed_issue_needs_note_sync(self) -> None:
        upsert_issue(self.conn, 1, self.issue("2026-06-07T00:00:00Z"), "2026-06-13T00:00:00Z")
        mark_issue_notes_synced(self.conn, 1, 340, "2026-06-13T00:00:00Z")

        self.assertTrue(issue_needs_note_sync(self.conn, 1, self.issue("2026-06-08T00:00:00Z")))

    def issue(self, updated_at: str) -> dict[str, object]:
        return {
            "iid": 340,
            "title": "Bug",
            "state": "opened",
            "created_at": "2026-06-01T00:00:00Z",
            "updated_at": updated_at,
            "closed_at": None,
            "assignee": {"username": "zhangli"},
            "web_url": "https://gitlab.local/project/windows-bug/-/issues/340",
        }


if __name__ == "__main__":
    unittest.main()
