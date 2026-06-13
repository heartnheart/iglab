from __future__ import annotations

import sqlite3
import unittest

from iglab_cli.db import initialize_database
from iglab_cli.gitlab import upsert_activity_note, upsert_issue
from iglab_cli.org_render import org_tag_name, render_org


class OrgRenderTest(unittest.TestCase):
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

    def test_render_starts_with_org_file_local_variables(self) -> None:
        org = render_org(self.conn)

        self.assertTrue(
            org.startswith("# -*- eval: (visual-fill-column-mode -1); eval: (display-line-numbers-mode -1); -*-\n")
        )

    def test_render_labels_as_org_tags_and_property(self) -> None:
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
                "labels": ["进行中", "P0/线上", "status::blocked"],
                "web_url": "https://gitlab.local/project/windows-bug/-/issues/340",
            },
            "2026-06-13T00:00:00Z",
        )

        org = render_org(self.conn)

        self.assertIn("*** TODO #340 Bug [login] :进行中:P0_线上:status_blocked:", org)
        self.assertIn(":GITLAB_LABELS: 进行中,P0/线上,status::blocked", org)
        self.assertIn(":GITLAB_CREATED_AT: 2026-06-01T00:00:00Z", org)
        self.assertIn(":GITLAB_UPDATED_AT: 2026-06-07T00:00:00Z", org)
        self.assertNotIn("- Created:", org)
        self.assertNotIn("- Updated:", org)
        self.assertNotIn(":LOCAL_NOTES:", org)

    def test_render_updated_url_property_to_latest_activity_note(self) -> None:
        upsert_issue(
            self.conn,
            1,
            {
                "iid": 340,
                "title": "Bug",
                "state": "opened",
                "created_at": "2026-06-01T00:00:00Z",
                "updated_at": "2026-06-07T00:00:00Z",
                "closed_at": None,
                "assignee": {"username": "zhangli"},
                "labels": [],
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

        org = render_org(self.conn)

        self.assertIn(
            ":GTLAB_UPDATED_URL: https://gitlab.local/project/windows-bug/-/issues/340#note_751087",
            org,
        )

    def test_render_preserves_existing_issue_body(self) -> None:
        upsert_issue(
            self.conn,
            1,
            {
                "iid": 340,
                "title": "Bug",
                "state": "opened",
                "created_at": "2026-06-01T00:00:00Z",
                "updated_at": "2026-06-07T00:00:00Z",
                "closed_at": None,
                "assignee": {"username": "zhangli"},
                "labels": [],
                "web_url": "https://gitlab.local/project/windows-bug/-/issues/340",
            },
            "2026-06-13T00:00:00Z",
        )
        existing_org = """#+TITLE: Old

* Issues
** project/windows-bug
*** TODO #340 Old title
:PROPERTIES:
:CUSTOM_ID: gitlab-project-windows-bug-340
:END:

keep this note
with two lines
"""

        org = render_org(self.conn, existing_org=existing_org)

        self.assertIn("keep this note\nwith two lines", org)
        self.assertIn("*** TODO #340 Bug", org)

    def test_render_migrates_legacy_local_notes_to_body(self) -> None:
        upsert_issue(
            self.conn,
            1,
            {
                "iid": 340,
                "title": "Bug",
                "state": "opened",
                "created_at": "2026-06-01T00:00:00Z",
                "updated_at": "2026-06-07T00:00:00Z",
                "closed_at": None,
                "assignee": {"username": "zhangli"},
                "labels": [],
                "web_url": "https://gitlab.local/project/windows-bug/-/issues/340",
            },
            "2026-06-13T00:00:00Z",
        )
        existing_org = """#+TITLE: Old

* Issues
** project/windows-bug
*** TODO #340 Old title
:PROPERTIES:
:CUSTOM_ID: gitlab-project-windows-bug-340
:END:

- Created: 2026-06-01T00:00:00Z
- Updated: [[https://gitlab.local/project/windows-bug/-/issues/340][2026-06-07T00:00:00Z]]

:LOCAL_NOTES:
legacy note
:END:
"""

        org = render_org(self.conn, existing_org=existing_org)

        self.assertIn("\nlegacy note\n", org)
        self.assertNotIn("- Created:", org)
        self.assertNotIn("- Updated:", org)
        self.assertNotIn(":LOCAL_NOTES:", org)

    def test_org_tag_name_sanitizes_separators(self) -> None:
        self.assertEqual(org_tag_name("status::blocked"), "status_blocked")
        self.assertEqual(org_tag_name("P0/线上"), "P0_线上")


if __name__ == "__main__":
    unittest.main()
