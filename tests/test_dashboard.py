from __future__ import annotations

import sqlite3
import unittest

from iglab_cli.dashboard import dashboard_issues
from iglab_cli.db import initialize_database
from iglab_cli.gitlab import upsert_activity_note, upsert_issue


class DashboardTest(unittest.TestCase):
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

    def test_dashboard_issue_shape(self) -> None:
        upsert_issue(
            self.conn,
            1,
            {
                "iid": 340,
                "title": "Bug [login]",
                "state": "opened",
                "created_at": "2026-06-01T00:00:00Z",
                "updated_at": "2026-06-07T00:00:00Z",
                "closed_at": None,
                "assignee": {"username": "zhangli"},
                "labels": ["other", "P0/线上", "status::blocked", "type::bug"],
                "web_url": "https://gitlab.local/project/windows-bug/-/issues/340",
            },
            "2026-06-13T00:00:00Z",
        )
        upsert_activity_note(
            self.conn,
            1,
            340,
            {
                "id": 751087,
                "created_at": "2026-06-07T00:00:00Z",
                "updated_at": "2026-06-07T00:00:00Z",
                "author": {"username": "pinghuang"},
                "system": True,
                "body": "assigned to @zhangli",
            },
        )

        issues = dashboard_issues(self.conn, state="opened")

        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0]["custom_id"], "gitlab-project-windows-bug-340")
        self.assertEqual(issues[0]["todo"], "TODO")
        self.assertEqual(issues[0]["assignee"], "zhangli")
        self.assertEqual(issues[0]["labels"], ["other", "P0/线上", "status::blocked", "type::bug"])
        self.assertEqual(
            issues[0]["updated_url"],
            "https://gitlab.local/project/windows-bug/-/issues/340#note_751087",
        )

    def test_state_filter(self) -> None:
        upsert_issue(self.conn, 1, self.issue(340, "opened"), "2026-06-13T00:00:00Z")
        upsert_issue(self.conn, 1, self.issue(341, "closed"), "2026-06-13T00:00:00Z")

        issues = dashboard_issues(self.conn, state="opened")

        self.assertEqual([issue["iid"] for issue in issues], [340])

    def issue(self, iid: int, state: str) -> dict[str, object]:
        return {
            "iid": iid,
            "title": f"Issue {iid}",
            "state": state,
            "created_at": "2026-06-01T00:00:00Z",
            "updated_at": "2026-06-07T00:00:00Z",
            "closed_at": None,
            "assignee": None,
            "labels": [],
            "web_url": f"https://gitlab.local/project/windows-bug/-/issues/{iid}",
        }


if __name__ == "__main__":
    unittest.main()
