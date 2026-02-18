import logging
import os
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List

from config import settings

_DB_INIT_LOCK = threading.Lock()
_DB_WRITE_LOCK = threading.Lock()
_DB_INITIALIZED = False


def _db_path() -> str:
    return settings.MOVE_LOG_DB_PATH


def _utc_now_iso() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _ensure_db() -> None:
    global _DB_INITIALIZED

    path = _db_path()
    if _DB_INITIALIZED and os.path.exists(path):
        return

    with _DB_INIT_LOCK:
        path = _db_path()
        parent_dir = os.path.dirname(path)
        if parent_dir:
            os.makedirs(parent_dir, exist_ok=True)

        with sqlite3.connect(path) as conn:
            conn.execute("PRAGMA journal_mode=WAL;")
            conn.execute("PRAGMA synchronous=NORMAL;")
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS move_logs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    source_path TEXT NOT NULL,
                    destination_path TEXT NOT NULL,
                    item_type TEXT NOT NULL,
                    trigger TEXT NOT NULL,
                    status TEXT NOT NULL,
                    note TEXT NOT NULL DEFAULT ''
                )
                """
            )
            conn.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_move_logs_created_at
                ON move_logs(created_at DESC)
                """
            )
            conn.commit()

        _DB_INITIALIZED = True


def _normalize_move_entry(entry: Dict[str, Any]) -> Dict[str, str]:
    return {
        "created_at": str(entry.get("created_at") or _utc_now_iso()),
        "source_path": str(entry.get("source_path") or ""),
        "destination_path": str(entry.get("destination_path") or ""),
        "item_type": str(entry.get("item_type") or "file"),
        "trigger": str(entry.get("trigger") or "plugin"),
        "status": str(entry.get("status") or "success"),
        "note": str(entry.get("note") or ""),
    }


def record_move(
    source_path: str,
    destination_path: str,
    item_type: str = "file",
    trigger: str = "plugin",
    status: str = "success",
    note: str = "",
) -> None:
    record_moves(
        [
            {
                "source_path": source_path,
                "destination_path": destination_path,
                "item_type": item_type,
                "trigger": trigger,
                "status": status,
                "note": note,
            }
        ]
    )


def record_moves(entries: List[Dict[str, Any]]) -> None:
    if not entries:
        return

    try:
        _ensure_db()
        normalized = [_normalize_move_entry(entry) for entry in entries]

        rows = [
            (
                entry["created_at"],
                entry["source_path"],
                entry["destination_path"],
                entry["item_type"],
                entry["trigger"],
                entry["status"],
                entry["note"],
            )
            for entry in normalized
        ]

        with _DB_WRITE_LOCK:
            with sqlite3.connect(_db_path()) as conn:
                conn.executemany(
                    """
                    INSERT INTO move_logs (
                        created_at,
                        source_path,
                        destination_path,
                        item_type,
                        trigger,
                        status,
                        note
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    rows,
                )
                conn.commit()
    except Exception as exc:
        logging.error(f"Failed to record move logs: {exc}")


def list_move_logs(hours: int = 24, limit: int = 200) -> List[Dict[str, Any]]:
    try:
        _ensure_db()

        safe_limit = max(1, min(limit, 1000))
        safe_hours = max(1, min(hours, 24 * 365))
        cutoff = (
            datetime.now(timezone.utc) - timedelta(hours=safe_hours)
        ).replace(microsecond=0)
        cutoff_iso = cutoff.isoformat().replace("+00:00", "Z")

        with sqlite3.connect(_db_path()) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT
                    id,
                    created_at,
                    source_path,
                    destination_path,
                    item_type,
                    trigger,
                    status,
                    note
                FROM move_logs
                WHERE created_at >= ?
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (cutoff_iso, safe_limit),
            ).fetchall()

        return [dict(row) for row in rows]
    except Exception as exc:
        logging.error(f"Failed to fetch move logs: {exc}")
        return []
