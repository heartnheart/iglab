# iglab

`iglab` is a local GitLab issue sync and Org dashboard prototype.

The current design treats GitLab as the source of truth, SQLite as the local
data layer, and Org as a generated view whose issue metadata is refreshed while
each issue body is preserved for private notes.

## Method

- Sync one GitLab instance.
- Discover projects from configured root groups recursively.
- Filter projects with include/exclude rules.
- Store current project and issue snapshots in SQLite.
- Store raw system activity notes in SQLite for future history queries.
- Parse assignee changes on demand from cached activity notes.
- Generate one `gitlab-issues.org` file from SQLite.
- Preserve each issue body during Org regeneration.
- Keep GitLab comments out of Org for the first version.

## Commands

Initialize the database:

```powershell
python -m iglab_cli --db .\cache.sqlite init-db
```

Render Org from the local database:

```powershell
python -m iglab_cli --db .\cache.sqlite render-org --output .\gitlab-issues.org
```

Sync active issues from GitLab before rendering:

```powershell
python -m iglab_cli --config .\iglab.local.json --db .\cache.sqlite sync active
python -m iglab_cli --db .\cache.sqlite render-org --output .\gitlab-issues.org
```

Show parsed assignee events for one issue:

```powershell
python -m iglab_cli --db .\cache.sqlite query assignee-events --project project/windows-bug --issue 340
```

Show issues assigned to a user at a point in time:

```powershell
python -m iglab_cli --db .\cache.sqlite query assignee-at --user zhangli --time 2026-06-13T10:00:00+08:00
```

Return dashboard issue JSON:

```powershell
python -m iglab_cli --db .\cache.sqlite query dashboard --state opened
```

## Emacs

Load `iglab.el`, then use:

```elisp
(setq iglab-gitlab-host "https://gitlab.internal")
(setq iglab-gitlab-token "glpat-...")
(setq iglab-root-groups '("project"))
```

Interactive commands:

- `M-x iglab-init-db`
- `M-x iglab-sync` starts an asynchronous sync and streams progress to `*iglab*`
- `M-x iglab-cancel` cancels a running sync
- `M-x iglab-render-org`
- `M-x iglab-open-org`
- `M-x iglab-dashboard`

The dashboard is a read-only `special-mode` view. It defaults to opened
issues, reads issue metadata through the Python CLI, and reads the first
non-empty paragraph from each Org issue body as the local note summary. It does
not render or modify the Org file automatically.

Dashboard keys:

- `RET` jumps to the issue in `iglab-org-file`
- `g` refreshes the dashboard
- `L` shows the full GitLab label list
- `b` opens the GitLab issue URL
- `q` quits the dashboard window

## Status

Implemented:

- SQLite schema.
- Python CLI command structure.
- Active-scope GitLab REST sync for projects, issues, and issue activity notes.
- Org renderer skeleton.
- Issue body preservation during Org regeneration.
- Assignee system note parser for the observed English GitLab text.
- Emacs wrapper commands.
- Read-only Emacs dashboard for issue browsing.

Pending:

- Resumable issue and activity-note sync.
- Label mapping into derived Org TODO states.
