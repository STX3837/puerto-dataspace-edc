from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse, urlunparse
import json
import os

import requests


ROOT = Path(__file__).resolve().parents[1]
GENERATED_DIR = ROOT / "resources" / "generated"
EVENTS_FILE = GENERATED_DIR / "ui-events.jsonl"


def running_in_docker() -> bool:
    return os.getenv("RUNNING_IN_DOCKER", "false").lower() == "true"


def host_url(url: str) -> str:
    if running_in_docker():
        return (
            url.replace("http://localhost:", "http://host.docker.internal:")
            .replace("http://127.0.0.1:", "http://host.docker.internal:")
        )
    return url


def replace_hostname(url: str, hostname: str) -> str:
    parsed = urlparse(url)
    if not parsed.netloc:
        return url
    port = f":{parsed.port}" if parsed.port else ""
    return urlunparse(parsed._replace(netloc=f"{hostname}{port}"))


def normalize_url_candidates(url: str) -> list[str]:
    candidates = [url, host_url(url)]
    parsed = urlparse(url)
    if parsed.hostname in {"localhost", "127.0.0.1"}:
        candidates.append(replace_hostname(url, "host.docker.internal"))
    if parsed.hostname == "host.docker.internal" and not running_in_docker():
        candidates.append(replace_hostname(url, "localhost"))
    if parsed.hostname == "regulatory-clearance-api":
        candidates.append(replace_hostname(url, "localhost"))
        candidates.append(replace_hostname(url, "host.docker.internal"))

    deduped = []
    for candidate in candidates:
        if candidate and candidate not in deduped:
            deduped.append(candidate)
    return deduped


def save_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def load_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return None


def write_ui_event(step: str, status: str, message: str, provider: str = "", data: dict | None = None):
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    event = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "step": step,
        "status": status,
        "provider": provider,
        "message": message,
        "data": data or {},
    }
    with EVENTS_FILE.open("a", encoding="utf-8") as file:
        file.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")


class HttpRequestError(Exception):
    def __init__(self, method, url, status_code=None, body="", message=""):
        self.method = method
        self.url = url
        self.status_code = status_code
        self.body = body
        super().__init__(message or f"{method} {url} failed with status {status_code}")


def request_json(method: str, url: str, headers=None, json_body=None, timeout=30):
    effective_url = host_url(url)
    try:
        response = requests.request(
            method,
            effective_url,
            headers=headers,
            json=json_body,
            timeout=timeout,
        )
    except requests.RequestException as exc:
        raise HttpRequestError(method, effective_url, message=str(exc)) from exc

    text = response.text
    if not 200 <= response.status_code < 300:
        raise HttpRequestError(method, effective_url, response.status_code, text)

    if not text:
        return {}
    try:
        return response.json()
    except ValueError:
        return text


def request_json_with_fallback(method: str, url: str, headers=None, json_body=None, timeout=30):
    last_error = None
    for candidate in normalize_url_candidates(url):
        try:
            return request_json(method, candidate, headers=headers, json_body=json_body, timeout=timeout), candidate
        except HttpRequestError as exc:
            last_error = exc
    if last_error:
        raise last_error
    raise HttpRequestError(method, url, message="No URL candidates available")
