from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path


DEFAULT_STATE_DIR = Path.home() / ".emacs.d" / "iglab"


@dataclass(frozen=True)
class Config:
    gitlab_host: str | None = None
    gitlab_token: str | None = None
    root_groups: tuple[str, ...] = ()
    project_paths: tuple[str, ...] = ()
    include_path_regexp: str | None = None
    exclude_path_regexp: str | None = None
    db_path: Path = field(default_factory=lambda: DEFAULT_STATE_DIR / "cache.sqlite")
    closed_lookback_days: int = 30


def load_config(path: Path | None = None, db_path: Path | None = None) -> Config:
    data: dict[str, object] = {}
    if path is not None and path.exists():
        data = json.loads(path.read_text(encoding="utf-8"))

    configured_db = data.get("db_path")
    resolved_db = db_path or (Path(configured_db) if isinstance(configured_db, str) else DEFAULT_STATE_DIR / "cache.sqlite")

    root_groups = data.get("root_groups", ())
    if not isinstance(root_groups, (list, tuple)):
        raise ValueError("root_groups must be a list of strings")

    project_paths = data.get("project_paths", ())
    if not isinstance(project_paths, (list, tuple)):
        raise ValueError("project_paths must be a list of strings")

    env_root_groups = os.environ.get("IGLAB_ROOT_GROUPS")
    if not root_groups and env_root_groups:
        root_groups = [group for group in env_root_groups.split(";") if group]

    env_project_paths = os.environ.get("IGLAB_PROJECT_PATHS")
    if not project_paths and env_project_paths:
        project_paths = [project for project in env_project_paths.split(";") if project]

    return Config(
        gitlab_host=_optional_str(data.get("gitlab_host")) or os.environ.get("IGLAB_GITLAB_HOST"),
        gitlab_token=_optional_str(data.get("gitlab_token")) or os.environ.get("IGLAB_GITLAB_TOKEN"),
        root_groups=tuple(str(group) for group in root_groups),
        project_paths=tuple(str(project) for project in project_paths),
        include_path_regexp=_optional_str(data.get("include_path_regexp")),
        exclude_path_regexp=_optional_str(data.get("exclude_path_regexp")),
        db_path=resolved_db,
        closed_lookback_days=int(data.get("closed_lookback_days", 30)),
    )


def _optional_str(value: object) -> str | None:
    if value is None:
        return None
    return str(value)
