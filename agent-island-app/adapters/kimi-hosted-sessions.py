#!/usr/bin/env python3
"""Read-only Kimi Hosted Agents session adapter.

The adapter prints Agent Island ConnectorTaskEvent JSONL. It never creates,
updates, interrupts, or archives a Kimi session.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def request_json(url: str, api_key: str, api_version: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {api_key}",
            "kimi-api-version": api_version,
            "Accept": "application/json",
        },
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=float(os.environ.get("KIMI_TIMEOUT_SECONDS", "10"))) as response:
        return json.load(response)


def load_fixture(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def emit(item: dict) -> None:
    session_id = str(item.get("id", "")).strip()
    if not session_id:
        return
    title = str(item.get("title") or f"Kimi 会话 {session_id}")
    now = datetime.now(timezone.utc).isoformat()
    print(json.dumps({
        "task_id": session_id,
        "title": title,
        "status": "running",
        "note": "Kimi Hosted Agent · 官方会话状态",
        "started_at": item.get("created_at") or now,
        "updated_at": item.get("updated_at") or now,
        "source": "kimi-hosted-agents",
    }, ensure_ascii=False))


def main() -> int:
    fixture = sys.argv[2] if len(sys.argv) == 3 and sys.argv[1] == "--fixture" else None
    try:
        if fixture:
            payload = load_fixture(fixture)
        else:
            api_key = os.environ.get("KIMI_API_KEY") or os.environ.get("MOONSHOT_API_KEY")
            if not api_key:
                raise RuntimeError("缺少 KIMI_API_KEY 或 MOONSHOT_API_KEY")
            base = os.environ.get("KIMI_API_BASE_URL", "https://api.moonshot.cn").rstrip("/")
            api_version = os.environ.get("KIMI_API_VERSION", "2026-09-01-beta")
            query = {
                "statuses": "running",
                "order": "updated_at_desc",
                "page_size": "100",
            }
            agent_id = os.environ.get("KIMI_AGENT_ID")
            if agent_id:
                query["agent_id"] = agent_id
            payload = request_json(f"{base}/v1/sessions?{urllib.parse.urlencode(query)}", api_key, api_version)

        for item in payload.get("items", []):
            if str(item.get("status", "")).lower() == "running":
                emit(item)
        return 0
    except Exception as exc:
        print(f"kimi-hosted-sessions: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
