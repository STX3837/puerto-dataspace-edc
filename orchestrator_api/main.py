from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import time
from uuid import uuid4

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel


COMMANDS = {
    "service_start": {
        "label": "Arrancar modo servicio",
        "script": "scripts/service-start.ps1",
    },
    "service_stop": {
        "label": "Parar modo servicio",
        "script": "scripts/service-stop.ps1",
    },
    "edc_start": {
        "label": "Arrancar EDC sin smoke",
        "script": "scripts/edc-start.ps1",
    },
    "demo_full": {
        "label": "Ejecutar demo completa",
        "script": "start-edc-and-smoke-three-providers.ps1",
    },
    "smoke_only": {
        "label": "Ejecutar solo smoke test",
        "script": "smoke-test-three-providers.ps1",
    },
}

app = FastAPI(title="Puerto Dataspace EDC Orchestrator API")
PROCESSES: dict[str, subprocess.Popen] = {}


class CommandInfo(BaseModel):
    name: str
    label: str
    script: str


class RunInfo(BaseModel):
    run_id: str
    command_name: str
    label: str
    status: str
    pid: int | None
    started_at: str
    finished_at: str | None
    exit_code: int | None
    log_file: str


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def generated_dir() -> Path:
    path = repo_root() / "resources" / "generated" / "orchestrator-runs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def metadata_path(run_id: str) -> Path:
    return generated_dir() / f"{run_id}.json"


def log_path(run_id: str) -> Path:
    return generated_dir() / f"{run_id}.log"


def relative(path: Path) -> str:
    try:
        return str(path.relative_to(repo_root())).replace("\\", "/")
    except ValueError:
        return str(path)


def load_run(run_id: str) -> dict:
    path = metadata_path(run_id)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Run no encontrado")
    return json.loads(path.read_text(encoding="utf-8"))


def save_run(data: dict) -> None:
    metadata_path(data["run_id"]).write_text(json.dumps(data, indent=2), encoding="utf-8")


def process_running(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-Command",
                f"$p = Get-Process -Id {int(pid)} -ErrorAction SilentlyContinue; if ($null -ne $p) {{ exit 0 }} else {{ exit 1 }}",
            ],
            cwd=str(repo_root()),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError, ValueError):
        return False


def refresh_run(data: dict) -> dict:
    if data.get("status") != "RUNNING":
        return data

    run_id = data["run_id"]
    process = PROCESSES.get(run_id)
    exit_code = process.poll() if process else None
    if process is None and process_running(data.get("pid")):
        return data

    if exit_code is None and process is None:
        exit_code = data.get("exit_code")
    if exit_code is None and process is not None:
        return data

    data["exit_code"] = exit_code
    data["finished_at"] = utc_now()
    data["status"] = "SUCCESS" if exit_code == 0 else "ERROR"
    save_run(data)
    PROCESSES.pop(run_id, None)
    return data


def all_runs() -> list[dict]:
    runs = []
    for path in sorted(generated_dir().glob("*.json"), reverse=True):
        try:
            runs.append(refresh_run(json.loads(path.read_text(encoding="utf-8"))))
        except (OSError, json.JSONDecodeError):
            continue
    return runs


def require_token(x_orchestrator_token: str | None = Header(default=None)) -> None:
    expected = os.getenv("ORCHESTRATOR_TOKEN", "")
    if not expected:
        print("WARNING: ORCHESTRATOR_TOKEN no definido. API orquestadora sin token.")
        return
    if x_orchestrator_token != expected:
        raise HTTPException(status_code=401, detail="Token de orquestador invalido")


@app.get("/health")
def health():
    return {"status": "UP", "time": utc_now()}


@app.get("/commands", dependencies=[Depends(require_token)])
def commands():
    return [
        CommandInfo(name=name, label=value["label"], script=value["script"])
        for name, value in COMMANDS.items()
    ]


@app.post("/commands/{command_name}/run", dependencies=[Depends(require_token)])
def run_command(command_name: str):
    if command_name not in COMMANDS:
        raise HTTPException(status_code=404, detail="Comando no permitido")

    running = [run for run in all_runs() if run.get("status") == "RUNNING"]
    if running:
        raise HTTPException(status_code=409, detail="Ya hay un proceso en ejecucion")

    command = COMMANDS[command_name]
    script_path = repo_root() / command["script"]
    if not script_path.exists():
        raise HTTPException(status_code=500, detail=f"Script no encontrado: {command['script']}")

    run_id = uuid4().hex
    log_file = log_path(run_id)
    log_handle = log_file.open("ab")
    try:
        process = subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script_path),
            ],
            cwd=str(repo_root()),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
        )
    except OSError as exc:
        log_handle.close()
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    log_handle.close()

    data = {
        "run_id": run_id,
        "command_name": command_name,
        "label": command["label"],
        "status": "RUNNING",
        "pid": process.pid,
        "started_at": utc_now(),
        "finished_at": None,
        "exit_code": None,
        "log_file": relative(log_file),
    }
    PROCESSES[run_id] = process
    save_run(data)
    return RunInfo(**data)


@app.get("/runs", dependencies=[Depends(require_token)])
def runs():
    return [RunInfo(**run) for run in all_runs()]


@app.get("/runs/{run_id}", dependencies=[Depends(require_token)])
def run(run_id: str):
    return RunInfo(**refresh_run(load_run(run_id)))


@app.get("/runs/{run_id}/log", response_class=PlainTextResponse, dependencies=[Depends(require_token)])
def run_log(run_id: str):
    load_run(run_id)
    path = log_path(run_id)
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


@app.post("/runs/{run_id}/stop", dependencies=[Depends(require_token)])
def stop_run(run_id: str):
    data = refresh_run(load_run(run_id))
    if data.get("status") != "RUNNING":
        return RunInfo(**data)

    process = PROCESSES.get(run_id)
    if process:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    else:
        subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-Command",
                f"Stop-Process -Id {int(data['pid'])} -Force -ErrorAction SilentlyContinue",
            ],
            cwd=str(repo_root()),
            check=False,
            timeout=10,
        )
        time.sleep(1)

    data["status"] = "STOPPED"
    data["finished_at"] = utc_now()
    data["exit_code"] = data.get("exit_code")
    save_run(data)
    PROCESSES.pop(run_id, None)
    return RunInfo(**data)
