#!/usr/bin/env python3
"""Read-only Qwen/DashScope asynchronous response adapter.

Qwen's response retrieval endpoint is keyed by response IDs. The IDs are read
from QWEN_RESPONSE_IDS_FILE (one ID per line, or a JSON array) or the
QWEN_RESPONSE_IDS comma-separated environment variable. This adapter only
retrieves status; it never creates or cancels a response.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def response_ids() -> list[str]:
    raw_file = os.environ.get("QWEN_RESPONSE_IDS_FILE")
    if raw_file:
        text = Path(raw_file).read_text(encoding="utf-8").strip()
        if text.startswith("["):
            values = json.loads(text)
            return [str(value.get("id", value)).strip() for value in values if str(value.get("id", value)).strip()]
        return [line.strip() for line in text.splitlines() if line.strip()]
    return [value.strip() for value in os.environ.get("QWEN_RESPONSE_IDS", "").split(",") if value.strip()]


def request_json(url: str, api_key: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {api_key}", "Accept": "application/json"},
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=float(os.environ.get("QWEN_TIMEOUT_SECONDS", "10"))) as response:
        return json.load(response)


def emit(response: dict) -> None:
    response_id = str(response.get("id", "")).strip()
    status = str(response.get("status", "")).lower()
    if not response_id:
        return
    # Agent Island currently has five public states. Qwen's queued/running/
    # completed/failed states map directly; cancelled/incomplete are reported
    # on stderr and omitted until the dashboard adds a first-class cancelled state.
    mapped = {"queued": "queued", "in_progress": "running", "completed": "done", "failed": "failed"}.get(status)
    if not mapped:
        print(f"qwen-responses: skipped {response_id} status={status or 'unknown'}", file=sys.stderr)
        return
    now = datetime.now(timezone.utc).isoformat()
    created = response.get("created_at") or now
    updated = response.get("updated_at") or created
    print(json.dumps({
        "task_id": response_id,
        "title": str(response.get("metadata", {}).get("title") or f"Qwen 响应 {response_id}"),
        "status": mapped,
        "note": f"Qwen/DashScope · {status}",
        "started_at": str(created),
        "updated_at": str(updated),
        "source": "qwen-dashscope-responses",
    }, ensure_ascii=False))


def main() -> int:
    fixture = sys.argv[2] if len(sys.argv) == 3 and sys.argv[1] == "--fixture" else None
    try:
        api_key = os.environ.get("DASHSCOPE_API_KEY")
        app_id = os.environ.get("QWEN_APP_ID")
        if not fixture and (not api_key or not app_id):
            raise RuntimeError("缺少 DASHSCOPE_API_KEY 或 QWEN_APP_ID")
        ids = response_ids()
        if not fixture and not ids:
            raise RuntimeError("没有 QWEN_RESPONSE_IDS_FILE 或 QWEN_RESPONSE_IDS")

        base = os.environ.get("QWEN_API_BASE_URL", "https://dashscope.aliyuncs.com/api/v2/apps/agent").rstrip("/")
        if fixture:
            emit(json.loads(Path(fixture).read_text(encoding="utf-8")))
        else:
            for response_id in ids:
                emit(request_json(f"{base}/{app_id}/compatible-mode/v1/responses/{response_id}", api_key))
        return 0
    except Exception as exc:
        print(f"qwen-responses: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
