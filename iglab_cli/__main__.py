from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .assignee import assignee_at, parse_assignee_events_for_issue
from .config import Config, load_config
from .db import connect, initialize_database
from .gitlab import GitLabClient
from .org_render import render_org


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="iglab", description="Sync GitLab issues into SQLite and Org.")
    parser.add_argument("--config", type=Path, help="Path to iglab JSON config.")
    parser.add_argument("--db", type=Path, help="Path to SQLite database.")

    subparsers = parser.add_subparsers(dest="command", required=True)

    init_db = subparsers.add_parser("init-db", help="Initialize the SQLite database schema.")
    init_db.set_defaults(func=cmd_init_db)

    sync = subparsers.add_parser("sync", help="Sync active issues. GitLab API implementation is pending.")
    sync.add_argument("scope", choices=("active", "all"), nargs="?", default="active")
    sync.set_defaults(func=cmd_sync)

    backfill = subparsers.add_parser("backfill", help="Backfill historical data. GitLab API implementation is pending.")
    backfill.add_argument("scope", choices=("all",), default="all")
    backfill.set_defaults(func=cmd_backfill)

    render = subparsers.add_parser("render-org", help="Render an Org file from SQLite.")
    render.add_argument("--output", type=Path, required=True)
    render.set_defaults(func=cmd_render_org)

    query = subparsers.add_parser("query", help="Run local SQLite queries.")
    query_sub = query.add_subparsers(dest="query_command", required=True)

    events = query_sub.add_parser("assignee-events", help="Show parsed assignee events for one issue.")
    events.add_argument("--project", required=True, help="Project path_with_namespace.")
    events.add_argument("--issue", type=int, required=True, help="Issue IID.")
    events.set_defaults(func=cmd_assignee_events)

    at = query_sub.add_parser("assignee-at", help="List issues assigned to a user at a point in time.")
    at.add_argument("--user", required=True, help="GitLab username.")
    at.add_argument("--time", required=True, help="ISO timestamp.")
    at.set_defaults(func=cmd_assignee_at)

    return parser


def resolve_config(args: argparse.Namespace) -> Config:
    return load_config(args.config, db_path=args.db)


def cmd_init_db(args: argparse.Namespace) -> int:
    config = resolve_config(args)
    with connect(config.db_path) as conn:
        initialize_database(conn)
    print(f"Initialized {config.db_path}")
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    config = resolve_config(args)
    with connect(config.db_path) as conn:
        initialize_database(conn)
        if args.scope == "active":
            GitLabClient(config).sync_active(conn, progress=_progress)
        else:
            print("sync all is not implemented yet; use backfill all once the backfill worker is implemented.")
            return 1
    print(f"Synced {args.scope} issues into {config.db_path}")
    return 0


def _progress(message: str) -> None:
    print(message, flush=True)


def cmd_backfill(args: argparse.Namespace) -> int:
    config = resolve_config(args)
    with connect(config.db_path) as conn:
        initialize_database(conn)
    print(f"backfill {args.scope}: resumable GitLab notes backfill is not implemented yet.")
    return 0


def cmd_render_org(args: argparse.Namespace) -> int:
    config = resolve_config(args)
    existing_org = args.output.read_text(encoding="utf-8") if args.output.exists() else None
    with connect(config.db_path) as conn:
        initialize_database(conn)
        text = render_org(conn, existing_org=existing_org)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = args.output.with_suffix(args.output.suffix + ".tmp")
    tmp_path.write_text(text, encoding="utf-8")
    tmp_path.replace(args.output)
    print(f"Rendered {args.output}")
    return 0


def cmd_assignee_events(args: argparse.Namespace) -> int:
    config = resolve_config(args)
    with connect(config.db_path) as conn:
        events = parse_assignee_events_for_issue(conn, args.project, args.issue)
    for event in events:
        print(json.dumps(event.to_dict(), ensure_ascii=False))
    return 0


def cmd_assignee_at(args: argparse.Namespace) -> int:
    config = resolve_config(args)
    with connect(config.db_path) as conn:
        matches = assignee_at(conn, args.user, args.time)
    print(json.dumps([match.to_dict() for match in matches], ensure_ascii=False, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"iglab: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
