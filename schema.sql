PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS projects (
    id INTEGER PRIMARY KEY,
    path_with_namespace TEXT NOT NULL UNIQUE,
    web_url TEXT,
    archived INTEGER NOT NULL DEFAULT 0,
    raw_json TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS issues (
    project_id INTEGER NOT NULL,
    iid INTEGER NOT NULL,
    title TEXT NOT NULL,
    state TEXT NOT NULL,
    created_at TEXT,
    updated_at TEXT,
    closed_at TEXT,
    assignee_username TEXT,
    labels_json TEXT NOT NULL DEFAULT '[]',
    web_url TEXT,
    raw_json TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    PRIMARY KEY (project_id, iid),
    FOREIGN KEY (project_id) REFERENCES projects(id)
);

CREATE TABLE IF NOT EXISTS issue_activity_notes (
    project_id INTEGER NOT NULL,
    issue_iid INTEGER NOT NULL,
    note_id INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT,
    author_username TEXT,
    system INTEGER NOT NULL DEFAULT 0,
    body TEXT NOT NULL,
    raw_json TEXT NOT NULL,
    PRIMARY KEY (project_id, issue_iid, note_id),
    FOREIGN KEY (project_id, issue_iid) REFERENCES issues(project_id, iid)
);

CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS project_sync_state (
    project_id INTEGER NOT NULL,
    scope TEXT NOT NULL,
    issues_synced_at TEXT,
    notes_backfill_status TEXT NOT NULL DEFAULT 'pending',
    notes_cursor TEXT,
    last_error TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (project_id, scope),
    FOREIGN KEY (project_id) REFERENCES projects(id)
);

CREATE TABLE IF NOT EXISTS issue_note_sync_state (
    project_id INTEGER NOT NULL,
    issue_iid INTEGER NOT NULL,
    backfill_status TEXT NOT NULL DEFAULT 'pending',
    last_note_id INTEGER,
    last_synced_at TEXT,
    last_error TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (project_id, issue_iid),
    FOREIGN KEY (project_id, issue_iid) REFERENCES issues(project_id, iid)
);

CREATE INDEX IF NOT EXISTS idx_projects_path
    ON projects(path_with_namespace);

CREATE INDEX IF NOT EXISTS idx_issues_project_state_updated
    ON issues(project_id, state, updated_at);

CREATE INDEX IF NOT EXISTS idx_issues_assignee
    ON issues(assignee_username);

CREATE INDEX IF NOT EXISTS idx_issue_activity_notes_issue_created
    ON issue_activity_notes(project_id, issue_iid, created_at);

CREATE INDEX IF NOT EXISTS idx_issue_activity_notes_created
    ON issue_activity_notes(created_at);
