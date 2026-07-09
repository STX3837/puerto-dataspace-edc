from datetime import datetime
from pathlib import Path
import json
import subprocess

import streamlit as st


ROOT = Path(__file__).resolve().parents[1]
GENERATED_DIR = ROOT / "resources" / "generated"
EVENTS_FILE = GENERATED_DIR / "ui-events.jsonl"
RUN_STATE_FILE = GENERATED_DIR / "ui-run-state.json"
RUN_LOG_FILE = GENERATED_DIR / "ui-script-run.log"
MAIN_SCRIPT = ROOT / "start-edc-and-smoke-three-providers.ps1"
START_ONLY_SCRIPT = ROOT / "start-edc-three-providers.ps1"
SMOKE_SCRIPT = ROOT / "smoke-test-three-providers.ps1"
AUTO_REFRESH_INTERVAL = "1s"

GLOBAL_STEPS = [
    "script_started",
    "infra_check",
    "identityhubs_ready",
    "issuer_ready",
    "participants_activation",
    "membership_credentials",
    "transport_company_credential",
    "vault_provisioning",
    "controlplanes_dataplanes",
    "assets_policies_contracts",
    "dataplanes_available",
    "smoke_test",
    "aggregation",
    "result",
    "script_finished",
]

PROVIDERS = ["customs", "health", "civilguard"]
PROVIDER_STEPS = ["catalog", "contract_negotiation", "transfer", "edr", "download"]

RESET_PATTERNS = [
    "ui-events.jsonl",
    "ui-run-state.json",
    "ui-script-run.log",
    "aggregated-clearance-status.json",
    "downloaded-*-clearance.json",
    "edr-*-response.json",
    "catalog-*-response.json",
    "contract-negotiation-request-*.json",
    "transfer-request-*.json",
]

STEP_EXPLANATIONS = {
    "script_started": "Inicializando el flujo completo de validación de la demo.",
    "infra_check": "Arrancando y comprobando PostgreSQL, Mock API y servicios base necesarios.",
    "identityhubs_ready": "Esperando a que los Identity Hubs respondan en sus endpoints de readiness.",
    "issuer_ready": "Esperando a que IssuerService esté disponible para emitir credenciales.",
    "participants_activation": "Activando los participantes del dataspace en sus Identity Hubs.",
    "membership_credentials": "Comprobando o solicitando MembershipCredential para Consumer y Providers.",
    "transport_company_credential": "Registrando y emitiendo la TransportCompanyCredential del Consumer.",
    "vault_provisioning": "Comprobando y provisionando claves privadas y secretos en Vault.",
    "controlplanes_dataplanes": "Construyendo/arrancando Control Planes y Data Planes.",
    "assets_policies_contracts": "Registrando assets, policies y contract definitions en los Providers.",
    "dataplanes_available": "Verificando que los Data Planes estén anunciados como AVAILABLE.",
    "smoke_test": "Ejecutando el smoke test multi-provider.",
    "catalog": "Solicitando el catálogo DSP del Provider y buscando el asset esperado.",
    "contract_negotiation": "Negociando contrato con el Provider usando la policy recibida.",
    "transfer": "Iniciando una transferencia HttpData-PULL para el asset contratado.",
    "edr": "Solicitando el Endpoint Data Reference para poder descargar el dato.",
    "download": "Descargando el dato desde el Data Plane mediante el EDR.",
    "aggregation": "Combinando las respuestas de Customs, Health y CivilGuard.",
    "result": "Evaluando si el contenedor queda listo para retirada.",
    "script_finished": "El flujo principal ha finalizado.",
}


def load_events() -> list[dict]:
    if not EVENTS_FILE.exists():
        return []

    events = []
    for line in EVENTS_FILE.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
            if isinstance(event, dict):
                events.append(event)
        except json.JSONDecodeError:
            continue
    return events


def load_json(path: Path):
    if not path.exists():
        return None

    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return None


def save_json(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def reset_generated_state():
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    for pattern in RESET_PATTERNS:
        for path in GENERATED_DIR.glob(pattern):
            if path.name == ".gitkeep" or not path.is_file():
                continue
            try:
                path.unlink()
            except OSError:
                pass


def is_process_running(pid: int | None) -> bool:
    if not pid:
        return False

    try:
        result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-Command",
                (
                    "$p = Get-CimInstance Win32_Process -Filter \"ProcessId = "
                    f"{int(pid)}\" -ErrorAction SilentlyContinue; "
                    "if ($p) { $p.CommandLine }"
                ),
            ],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.SubprocessError, ValueError):
        return False

    command_line = result.stdout.lower()
    script_names = {
        MAIN_SCRIPT.name.lower(),
        START_ONLY_SCRIPT.name.lower(),
        SMOKE_SCRIPT.name.lower(),
    }
    return any(script_name in command_line for script_name in script_names)


def current_run_state() -> dict:
    state = load_json(RUN_STATE_FILE) or {}
    pid = state.get("pid")
    state["running"] = is_process_running(pid)
    return state


def start_script(script: Path, reset_state: bool, label: str) -> tuple[bool, str]:
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    state = current_run_state()
    if state.get("running"):
        return False, f"Ya hay una ejecución en curso (PID {state.get('pid')})."

    if reset_state:
        reset_generated_state()
    log_handle = RUN_LOG_FILE.open("ab")
    creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)

    try:
        process = subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script),
            ],
            cwd=str(ROOT),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            creationflags=creationflags,
        )
    except OSError as exc:
        log_handle.close()
        return False, f"No se pudo arrancar el script: {exc}"

    log_handle.close()
    save_json(
        RUN_STATE_FILE,
        {
            "pid": process.pid,
            "startedAt": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "script": str(script),
            "label": label,
            "log": str(RUN_LOG_FILE),
        },
    )
    return True, f"{label} arrancado en segundo plano (PID {process.pid})."


def start_main_script() -> tuple[bool, str]:
    return start_script(MAIN_SCRIPT, reset_state=True, label="Demo completa")


def start_services_script() -> tuple[bool, str]:
    return start_script(START_ONLY_SCRIPT, reset_state=True, label="Arranque EDC")


def start_smoke_script() -> tuple[bool, str]:
    return start_script(SMOKE_SCRIPT, reset_state=True, label="Smoke test")


def latest_status(events: list[dict], step: str, provider: str | None = None) -> str:
    provider_filter = provider.lower() if provider else None
    for event in reversed(events):
        event_provider = str(event.get("provider", "")).lower()
        if event.get("step") != step:
            continue
        if provider_filter is not None and event_provider != provider_filter:
            continue
        return str(event.get("status", "PENDING")).upper()
    return "PENDING"


def latest_event(events: list[dict]) -> dict | None:
    return events[-1] if events else None


def read_log_tail(max_lines: int = 12) -> list[str]:
    if not RUN_LOG_FILE.exists():
        return []

    try:
        lines = RUN_LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    return lines[-max_lines:]


def status_icon(status: str) -> str:
    return {
        "SUCCESS": "✅",
        "RUNNING": "🔄",
        "ERROR": "❌",
        "PENDING": "⏳",
        "SKIPPED": "⏭️",
    }.get(status.upper(), "⏳")


def global_status(events: list[dict]) -> str:
    finished = latest_status(events, "script_finished")
    if finished in {"SUCCESS", "ERROR"}:
        return finished
    result = latest_status(events, "result")
    if result == "ERROR":
        return "ERROR"
    latest = latest_event(events)
    return str(latest.get("status", "PENDING")).upper() if latest else "PENDING"


def display_status(events: list[dict], step: str) -> str:
    status = latest_status(events, step)
    finished = latest_status(events, "script_finished")

    if step == "script_started" and status == "PENDING" and events:
        return "SUCCESS" if finished == "SUCCESS" else "RUNNING"
    if finished == "SUCCESS" and status == "RUNNING":
        return "SUCCESS"
    return status


def should_auto_refresh(events: list[dict]) -> bool:
    if current_run_state().get("running"):
        return True

    latest = latest_event(events)
    if not latest or global_status(events) != "RUNNING":
        return False

    try:
        timestamp = datetime.strptime(latest.get("timestamp", ""), "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False

    age_seconds = (datetime.utcnow() - timestamp).total_seconds()
    return age_seconds < 1800


def render_auto_refresh(events: list[dict]):
    return


def fragment_decorator(run_every: str | None):
    fragment = getattr(st, "fragment", None) or getattr(st, "experimental_fragment", None)
    if fragment is None:
        return lambda func: func
    return fragment(run_every=run_every)


def render_script_controls():
    st.subheader("Ejecución")
    state = current_run_state()
    running = state.get("running", False)

    col1, col2, col3, col4 = st.columns([1, 1, 1, 3])
    with col1:
        if st.button("Ejecutar demo completa", disabled=running):
            ok, message = start_main_script()
            if ok:
                st.success(message)
                st.rerun()
            else:
                st.warning(message)

    with col2:
        if st.button("Arrancar EDC sin smoke", disabled=running):
            ok, message = start_services_script()
            if ok:
                st.success(message)
                st.rerun()
            else:
                st.warning(message)

    with col3:
        if st.button("Ejecutar solo smoke test", disabled=running):
            ok, message = start_smoke_script()
            if ok:
                st.success(message)
                st.rerun()
            else:
                st.warning(message)

    with col4:
        if running:
            st.info(f"Script en ejecución. PID: {state.get('pid')}. Auto-recarga suave cada 1 segundo.")
        elif state.get("pid"):
            st.caption(f"Última ejecución registrada: PID {state.get('pid')}. Log: {RUN_LOG_FILE}")
        else:
            st.caption("Puedes lanzar el flujo completo desde la UI o desde una consola.")


def progress_percent(events: list[dict]) -> int:
    statuses = {step: display_status(events, step) for step in GLOBAL_STEPS}
    completed = sum(1 for status in statuses.values() if status == "SUCCESS")
    state = global_status(events)
    return 100 if state == "SUCCESS" else int((completed / len(GLOBAL_STEPS)) * 100)


def render_global_summary(events: list[dict]):
    latest = latest_event(events)
    state = global_status(events)
    percent = progress_percent(events)

    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Estado global", f"{status_icon(state)} {state}")
    col2.metric("Progreso", f"{percent}%")
    col3.markdown("**Último evento**")
    col3.code(latest.get("step", "Pendiente") if latest else "Pendiente")
    col4.markdown("**Timestamp**")
    col4.code(latest.get("timestamp", "Pendiente") if latest else "Pendiente")

    st.progress(percent / 100)


def render_global_progress(events: list[dict]):
    statuses = {step: display_status(events, step) for step in GLOBAL_STEPS}
    st.subheader("Flujo global")

    rows = []
    for step in GLOBAL_STEPS:
        status = statuses[step]
        rows.append(
            {
                "Paso": step,
                "Estado": f"{status_icon(status)} {status}",
                "Mensaje": latest_message(events, step),
            }
        )
    st.dataframe(rows, use_container_width=True, hide_index=True)


def render_current_activity(events: list[dict]):
    st.subheader("Qué está ocurriendo ahora")
    latest = latest_event(events)

    if not latest:
        st.info("Pendiente: todavía no hay eventos de ejecución.")
        return

    status = str(latest.get("status", "PENDING")).upper()
    step = str(latest.get("step", ""))
    provider = str(latest.get("provider", ""))
    message = str(latest.get("message", ""))
    explanation = STEP_EXPLANATIONS.get(step, "Ejecutando una fase del flujo de la demo.")

    title = f"{status_icon(status)} {step}"
    if provider:
        title = f"{title} · {provider}"

    if status == "ERROR":
        st.error(title)
    elif status == "SUCCESS":
        st.success(title)
    elif status == "RUNNING":
        st.info(title)
    else:
        st.warning(title)

    st.write(message)
    st.caption(explanation)


    recent_events = events[-8:]
    if recent_events:
        st.markdown("#### Últimos mensajes del flujo")
        event_lines = []
        for event in recent_events:
            provider_text = f" [{event.get('provider')}]" if event.get("provider") else ""
            event_lines.append(
                f"{event.get('timestamp', '')} {event.get('status', '')} "
                f"{event.get('step', '')}{provider_text}: {event.get('message', '')}"
            )
        st.code("\n".join(event_lines), language="text")


def latest_message(events: list[dict], step: str, provider: str | None = None) -> str:
    provider_filter = provider.lower() if provider else None
    for event in reversed(events):
        event_provider = str(event.get("provider", "")).lower()
        if event.get("step") != step:
            continue
        if provider_filter is not None and event_provider != provider_filter:
            continue
        return str(event.get("message", ""))
    return "Pendiente"


def render_provider_status(events: list[dict]):
    st.subheader("Estado por Provider")
    columns = st.columns(len(PROVIDERS))

    for column, provider in zip(columns, PROVIDERS):
        with column:
            st.markdown(f"#### {provider}")
            rows = []
            for step in PROVIDER_STEPS:
                status = latest_status(events, step, provider)
                rows.append(
                    {
                        "Paso": step,
                        "Estado": f"{status_icon(status)} {status}",
                        "Mensaje": latest_message(events, step, provider),
                    }
                )
            st.dataframe(rows, use_container_width=True, hide_index=True)


def format_value(value):
    if value in (None, ""):
        return "Pendiente"
    if isinstance(value, list):
        return ", ".join(str(item) for item in value) if value else "Ninguno"
    return str(value)


def render_raw_json(title: str, data):
    with st.expander(f"Ver JSON original - {title}", expanded=False):
        if data is None:
            st.info("Pendiente")
        else:
            st.json(data)


def render_clearance_card(provider: str, data):
    with st.container(border=True):
        st.markdown(f"#### {provider}")
        if data is None:
            st.info("Pendiente")
            return

        st.metric("Estado", format_value(data.get("status")))
        st.caption(f"Autoridad: {format_value(data.get('authority'))}")
        st.caption(f"Contenedor: {format_value(data.get('containerId'))}")
        st.caption(f"Actualizado: {format_value(data.get('lastUpdatedAt'))}")


def render_edr_card(provider: str, data):
    with st.container(border=True):
        st.markdown(f"#### EDR {provider}")
        if data is None:
            st.info("Pendiente")
            return

        token = data.get("authorization") or data.get("authCode")
        token_preview = f"{token[:24]}..." if token else "Pendiente"

        st.caption(f"Tipo: {format_value(data.get('type'))}")
        st.caption(f"Endpoint: `{format_value(data.get('endpoint'))}`")
        st.caption(f"Autenticación: {format_value(data.get('authType'))}")
        st.caption(f"Token: `{token_preview}`")


def render_aggregate_summary(data):
    if data is None:
        st.info("Resultado agregado final: Pendiente")
        return

    st.success(f"Resultado agregado final: {format_value(data.get('overallStatus'))}")
    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Contenedor", format_value(data.get("containerId")))
    col2.metric("Customs", format_value(data.get("customsStatus")))
    col3.metric("Health", format_value(data.get("healthInspectionStatus")))
    col4.metric("CivilGuard", format_value(data.get("civilGuardStatus")))

    st.caption(f"Bloqueos: {format_value(data.get('blockingAuthorities'))}")
    st.caption(f"Última actualización: {format_value(data.get('lastUpdatedAt'))}")


def render_artifacts():
    st.subheader("Artefactos")

    downloads = {
        "Customs": load_json(GENERATED_DIR / "downloaded-customs-clearance.json"),
        "Health": load_json(GENERATED_DIR / "downloaded-health-clearance.json"),
        "CivilGuard": load_json(GENERATED_DIR / "downloaded-civilguard-clearance.json"),
    }
    edrs = {
        "Customs": load_json(GENERATED_DIR / "edr-customs-response.json"),
        "Health": load_json(GENERATED_DIR / "edr-health-response.json"),
        "CivilGuard": load_json(GENERATED_DIR / "edr-civilguard-response.json"),
    }
    aggregate = load_json(GENERATED_DIR / "aggregated-clearance-status.json")

    render_aggregate_summary(aggregate)

    st.markdown("#### Datos descargados por Provider")
    download_cols = st.columns(3)
    for column, (provider, data) in zip(download_cols, downloads.items()):
        with column:
            render_clearance_card(provider, data)

    st.markdown("#### Endpoint Data References")
    edr_cols = st.columns(3)
    for column, (provider, data) in zip(edr_cols, edrs.items()):
        with column:
            render_edr_card(provider, data)


def render_original_json_artifacts():
    st.subheader("JSON originales")

    downloads = {
        "Customs": load_json(GENERATED_DIR / "downloaded-customs-clearance.json"),
        "Health": load_json(GENERATED_DIR / "downloaded-health-clearance.json"),
        "CivilGuard": load_json(GENERATED_DIR / "downloaded-civilguard-clearance.json"),
    }
    edrs = {
        "Customs": load_json(GENERATED_DIR / "edr-customs-response.json"),
        "Health": load_json(GENERATED_DIR / "edr-health-response.json"),
        "CivilGuard": load_json(GENERATED_DIR / "edr-civilguard-response.json"),
    }
    aggregate = load_json(GENERATED_DIR / "aggregated-clearance-status.json")

    render_raw_json("Resultado agregado", aggregate)
    for provider, data in downloads.items():
        render_raw_json(f"Descarga {provider}", data)
    for provider, data in edrs.items():
        render_raw_json(f"EDR {provider}", data)


def render_event_log(events: list[dict]):
    st.subheader("Timeline de eventos")
    if not events:
        st.info("Pendiente: todavía no hay eventos en resources/generated/ui-events.jsonl")
        return

    rows = []
    for event in events:
        status = str(event.get("status", "PENDING")).upper()
        rows.append(
            {
                "timestamp": event.get("timestamp", ""),
                "step": event.get("step", ""),
                "provider": event.get("provider", ""),
                "status": f"{status_icon(status)} {status}",
                "message": event.get("message", ""),
                "data": json.dumps(event.get("data", {}), ensure_ascii=False),
            }
        )
    st.dataframe(rows, use_container_width=True, hide_index=True)


def render_commands():
    with st.expander("Comandos útiles"):
        st.code(
            """docker compose -f .\\docker-compose.infra.yml up -d
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\start-edc-and-smoke-three-providers.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\start-edc-three-providers.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\smoke-test-three-providers.ps1
streamlit run .\\ui\\app.py""",
            language="powershell",
        )


def render_manual_flow_link():
    page_path = "pages/1_Manual_Provider_Flow.py"
    if hasattr(st, "page_link"):
        st.page_link(page_path, label="Abrir flujo manual por Provider")
        return

    if st.button("Abrir flujo manual por Provider"):
        st.switch_page(page_path)


def main():
    st.set_page_config(page_title="Puerto Dataspace EDC - Demo Monitor", layout="wide")

    st.title("Puerto Dataspace EDC - Demo Monitor")
    st.caption(
        "La página puede refrescarse manualmente mientras el script escribe eventos. "
        f"Última lectura UI: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
    )

    if st.button("Actualizar"):
        st.rerun()

    render_manual_flow_link()

    initial_events = load_events()
    auto_refresh = should_auto_refresh(initial_events)

    @fragment_decorator(AUTO_REFRESH_INTERVAL if auto_refresh else None)
    def render_live_content():
        events = load_events()
        if auto_refresh and not should_auto_refresh(events):
            st.rerun()
        render_script_controls()
        render_global_summary(events)
        render_artifacts()
        render_current_activity(events)
        render_global_progress(events)
        render_provider_status(events)
        render_original_json_artifacts()
        render_event_log(events)

    render_live_content()
    render_commands()


if __name__ == "__main__":
    main()
