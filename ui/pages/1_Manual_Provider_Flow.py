from copy import deepcopy
from copy import deepcopy
import base64
from datetime import datetime, timezone
from pathlib import Path
import json
import time

import requests
import streamlit as st


ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "resources"
GENERATED_DIR = RESOURCES / "generated"
EVENTS_FILE = GENERATED_DIR / "ui-events.jsonl"

CONSUMER_MGMT = "http://localhost:29193/management"
CONSUMER_KEY = "consumer-api-key"

PROVIDERS = {
    "customs": {
        "label": "Customs",
        "did": "did:web:provider-identityhub%3A8183:provider",
        "address": "http://provider-controlplane:19292/protocol",
        "management_url": "http://localhost:19193/management",
        "api_key": "provider-api-key",
        "asset_id": "asset-clearance-mscu7654321",
        "catalog_request": RESOURCES / "catalog" / "catalog-request.json",
        "internal_public_base": "http://provider-dataplane:19294",
        "local_public_base": "http://localhost:19294",
        "download_file": "downloaded-customs-clearance.json",
        "edr_file": "edr-customs-response.json",
    },
    "health": {
        "label": "Health",
        "did": "did:web:health-identityhub%3A8183:health",
        "address": "http://health-controlplane:19292/protocol",
        "management_url": "http://localhost:21193/management",
        "api_key": "provider-api-key",
        "asset_id": "asset-health-clearance-mscu7654321",
        "catalog_request": RESOURCES / "catalog" / "catalog-request-health.json",
        "internal_public_base": "http://health-dataplane:19294",
        "local_public_base": "http://localhost:21294",
        "download_file": "downloaded-health-clearance.json",
        "edr_file": "edr-health-response.json",
    },
    "civilguard": {
        "label": "CivilGuard",
        "did": "did:web:civilguard-identityhub%3A8183:civilguard",
        "address": "http://civilguard-controlplane:19292/protocol",
        "management_url": "http://localhost:22193/management",
        "api_key": "provider-api-key",
        "asset_id": "asset-civilguard-clearance-mscu7654321",
        "catalog_request": RESOURCES / "catalog" / "catalog-request-civilguard.json",
        "internal_public_base": "http://civilguard-dataplane:19294",
        "local_public_base": "http://localhost:22294",
        "download_file": "downloaded-civilguard-clearance.json",
        "edr_file": "edr-civilguard-response.json",
    },
}

MANUAL_KEYS = {
    "manual_provider",
    "manual_catalog_response",
    "manual_offers",
    "manual_selected_offer",
    "manual_negotiation_id",
    "manual_agreement_id",
    "manual_agreement_asset_id",
    "manual_negotiation_state",
    "manual_transfer_id",
    "manual_transfer_state",
    "manual_edr_response",
    "manual_download_response",
    "manual_error",
}


class HttpRequestError(Exception):
    def __init__(self, method: str, url: str, status_code=None, body="", message=""):
        self.method = method
        self.url = url
        self.status_code = status_code
        self.body = body
        super().__init__(message or f"{method} {url} failed with status {status_code}")


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


def write_ui_event(step: str, status: str, provider: str, message: str, data=None):
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


def request_json(method: str, url: str, headers=None, json_body=None, timeout=30):
    try:
        response = requests.request(
            method,
            url,
            headers=headers,
            json=json_body,
            timeout=timeout,
        )
    except requests.RequestException as exc:
        raise HttpRequestError(method, url, message=str(exc)) from exc

    text = response.text
    if not 200 <= response.status_code < 300:
        raise HttpRequestError(method, url, response.status_code, text)

    if not text:
        return {}

    try:
        return response.json()
    except ValueError:
        return text


def consumer_headers():
    return {
        "X-API-Key": CONSUMER_KEY,
        "Content-Type": "application/json",
    }


def provider_headers(provider: dict):
    return {
        "X-API-Key": provider["api_key"],
        "Content-Type": "application/json",
    }


def request_catalog(provider: dict) -> dict:
    payload = load_json(provider["catalog_request"])
    if payload is None:
        raise RuntimeError(f"No se pudo leer {provider['catalog_request']}")
    payload = deepcopy(payload)
    payload["querySpec"] = {
        "offset": 0,
        "limit": 100,
        "filterExpression": [],
    }

    return request_json(
        "POST",
        f"{CONSUMER_MGMT}/v3/catalog/request",
        headers=consumer_headers(),
        json_body=payload,
    )


def query_provider_collection(provider: dict, resource: str):
    payload = {
        "@context": {
            "@vocab": "https://w3id.org/edc/v0.0.1/ns/",
        },
        "@type": "QuerySpec",
        "offset": 0,
        "limit": 100,
    }
    return request_json(
        "POST",
        f"{provider['management_url']}/v3/{resource}/request",
        headers=provider_headers(provider),
        json_body=payload,
    )


def response_items(response):
    if isinstance(response, list):
        return response
    if isinstance(response, dict):
        for key in ("value", "content", "items", "results", "data"):
            value = response.get(key)
            if isinstance(value, list):
                return value
        return [response]
    return []


def resource_id(resource: dict):
    return resource.get("@id") or resource.get("id") or resource.get("edc:id")


def contract_asset_selector(contract_definition: dict):
    selectors = as_list(
        contract_definition.get("assetsSelector")
        or contract_definition.get("edc:assetsSelector")
    )
    for selector in selectors:
        if not isinstance(selector, dict):
            continue
        left = value_id(selector.get("operandLeft") or selector.get("edc:operandLeft"))
        right = selector.get("operandRight") or selector.get("edc:operandRight")
        if left == "https://w3id.org/edc/v0.0.1/ns/id":
            return value_id(right)
    return ""


def build_empty_catalog_diagnostics(provider: dict) -> list[str]:
    try:
        assets = response_items(query_provider_collection(provider, "assets"))
        policies = response_items(query_provider_collection(provider, "policydefinitions"))
        contracts = response_items(query_provider_collection(provider, "contractdefinitions"))
    except Exception as exc:
        return [f"No se pudo consultar la Management API del Provider para diagnosticarlo: {exc}"]

    asset_ids = {resource_id(asset) for asset in assets if isinstance(asset, dict)}
    policy_ids = {resource_id(policy) for policy in policies if isinstance(policy, dict)}
    messages = []

    if not assets:
        messages.append("El Provider no tiene Assets registrados.")
    if not policies:
        messages.append("El Provider no tiene Policies registradas.")
    if not contracts:
        messages.append("El Provider no tiene Contract Definitions registradas.")

    for contract in contracts:
        if not isinstance(contract, dict):
            continue
        contract_id = resource_id(contract) or "sin id"
        selector_asset_id = contract_asset_selector(contract)
        access_policy_id = contract.get("accessPolicyId") or contract.get("edc:accessPolicyId")
        contract_policy_id = contract.get("contractPolicyId") or contract.get("edc:contractPolicyId")

        if selector_asset_id and selector_asset_id not in asset_ids:
            messages.append(
                f"La Contract Definition `{contract_id}` apunta al Asset `{selector_asset_id}`, "
                "pero ese Asset no existe en el Provider."
            )
        if access_policy_id and access_policy_id not in policy_ids:
            messages.append(
                f"La Contract Definition `{contract_id}` usa la Access Policy `{access_policy_id}`, "
                "pero esa Policy no existe."
            )
        if contract_policy_id and contract_policy_id not in policy_ids:
            messages.append(
                f"La Contract Definition `{contract_id}` usa la Contract Policy `{contract_policy_id}`, "
                "pero esa Policy no existe."
            )

    if not messages:
        messages.append(
            "Hay Assets, Policies y Contract Definitions, pero ninguna se publica en el catalogo. "
            "Revisa que la Access Policy permita al Consumer ver la oferta."
        )

    return messages


def reset_after_catalog_request():
    for key in (
        "manual_selected_offer",
        "manual_negotiation_id",
        "manual_agreement_id",
        "manual_agreement_asset_id",
        "manual_negotiation_state",
        "manual_transfer_id",
        "manual_transfer_state",
        "manual_edr_response",
        "manual_download_response",
        "manual_error",
    ):
        st.session_state.pop(key, None)


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def extract_offers(catalog: dict) -> list[dict]:
    datasets = as_list(catalog.get("dcat:dataset") or catalog.get("dataset"))
    offers = []

    for dataset in datasets:
        if not isinstance(dataset, dict):
            continue
        asset_id = (
            dataset.get("@id")
            or dataset.get("id")
            or dataset.get("assetId")
            or dataset.get("edc:id")
        )
        policies = (
            dataset.get("odrl:hasPolicy")
            or dataset.get("odrl:offer")
            or dataset.get("policy")
            or dataset.get("hasPolicy")
        )
        for policy in as_list(policies):
            if not isinstance(policy, dict):
                continue
            offer_id = policy.get("@id") or policy.get("id")
            offers.append(
                {
                    "offer_id": offer_id,
                    "asset_id": asset_id,
                    "contract_definition_id": offer_contract_definition_id(offer_id),
                    "policy_id": "",
                    "dataset": dataset,
                    "policy": policy,
                }
            )

    return offers


def enrich_offer_policy_ids(provider: dict, offers: list[dict]) -> list[dict]:
    try:
        contracts = response_items(query_provider_collection(provider, "contractdefinitions"))
    except Exception:
        return offers

    by_asset = {}
    by_contract_definition = {}
    for contract in contracts:
        if not isinstance(contract, dict):
            continue
        contract_id = resource_id(contract)
        asset_id = contract_asset_selector(contract)
        contract_policy_id = contract.get("contractPolicyId") or contract.get("edc:contractPolicyId")
        access_policy_id = contract.get("accessPolicyId") or contract.get("edc:accessPolicyId")
        if not contract_policy_id:
            continue
        metadata = {
            "contract_definition_id": contract_id,
            "access_policy_id": access_policy_id,
            "policy_id": contract_policy_id,
        }
        if contract_id:
            by_contract_definition[contract_id] = metadata
        if asset_id and asset_id not in by_asset:
            by_asset[asset_id] = metadata

    enriched = []
    for offer in offers:
        metadata = (
            by_contract_definition.get(offer.get("contract_definition_id"))
            or by_asset.get(offer.get("asset_id"))
            or {}
        )
        enriched_offer = deepcopy(offer)
        enriched_offer.update({key: value for key, value in metadata.items() if value})
        enriched.append(enriched_offer)
    return enriched


def provider_contract_definition_rows(provider: dict, offers: list[dict]) -> list[dict]:
    offered_assets = {offer.get("asset_id") for offer in offers if offer.get("asset_id")}
    offered_policy_ids = {offer.get("policy_id") for offer in offers if offer.get("policy_id")}
    try:
        assets = response_items(query_provider_collection(provider, "assets"))
        policies = response_items(query_provider_collection(provider, "policydefinitions"))
        contracts = response_items(query_provider_collection(provider, "contractdefinitions"))
    except Exception as exc:
        return [
            {
                "contract definition id": "no disponible",
                "asset id": "",
                "access policy id": "",
                "contract policy id": "",
                "en catalogo": "No se pudo consultar",
                "detalle": str(exc),
            }
        ]

    asset_ids = {resource_id(asset) for asset in assets if isinstance(asset, dict)}
    policy_ids = {resource_id(policy) for policy in policies if isinstance(policy, dict)}
    rows = []
    for contract in contracts:
        if not isinstance(contract, dict):
            continue
        selector_asset_id = contract_asset_selector(contract)
        access_policy_id = contract.get("accessPolicyId") or contract.get("edc:accessPolicyId") or ""
        contract_policy_id = contract.get("contractPolicyId") or contract.get("edc:contractPolicyId") or ""
        is_published = selector_asset_id in offered_assets or contract_policy_id in offered_policy_ids
        detail = "Oferta negociable"
        if not is_published:
            if selector_asset_id not in asset_ids:
                detail = "El Asset selector no existe en el Provider"
            elif access_policy_id not in policy_ids:
                detail = "La Access Policy no existe"
            elif contract_policy_id not in policy_ids:
                detail = "La Contract Policy no existe"
            else:
                detail = "Registrada, pero la Access Policy no la publica para este Consumer"
        rows.append(
            {
                "contract definition id": resource_id(contract) or "sin id",
                "asset id": selector_asset_id or "sin selector",
                "access policy id": access_policy_id,
                "contract policy id": contract_policy_id,
                "en catalogo": "Si" if is_published else "No",
                "detalle": detail,
            }
        )
    return rows


def value_id(value):
    if isinstance(value, dict):
        return value.get("@id") or value.get("id") or json.dumps(value, ensure_ascii=False)
    return value


def decode_offer_id_part(offer_id: str, index: int) -> str:
    parts = str(offer_id or "").split(":")
    if index >= len(parts):
        return ""
    encoded = parts[index]
    padding = "=" * (-len(encoded) % 4)
    try:
        return base64.urlsafe_b64decode(f"{encoded}{padding}").decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return ""


def offer_contract_definition_id(offer_id: str) -> str:
    return decode_offer_id_part(offer_id, 0)


def summarize_constraints(constraints) -> str:
    parts = []
    for constraint in as_list(constraints):
        if not isinstance(constraint, dict):
            continue
        left = value_id(constraint.get("odrl:leftOperand") or constraint.get("leftOperand"))
        operator = value_id(constraint.get("odrl:operator") or constraint.get("operator"))
        right = value_id(constraint.get("odrl:rightOperand") or constraint.get("rightOperand"))
        parts.append(f"{left} {operator} {right}")
    return "; ".join(parts)


def summarize_offer(offer: dict) -> dict:
    policy = offer.get("policy") or {}
    permission = policy.get("odrl:permission") or policy.get("permission") or {}
    if isinstance(permission, list):
        permission = permission[0] if permission else {}
    action = value_id(permission.get("odrl:action") or permission.get("action"))
    constraints = permission.get("odrl:constraint") or permission.get("constraint")

    return {
        "asset id": offer.get("asset_id") or "sin asset",
        "contract definition id": offer.get("contract_definition_id") or "no disponible",
        "offer id": offer.get("offer_id") or "sin id",
        "policy id": offer.get("policy_id") or "sin policy",
        "permission/action": action or "no disponible",
        "constraints": summarize_constraints(constraints) or "sin constraints",
    }


def start_contract_negotiation(provider: dict, offer: dict) -> dict:
    policy = deepcopy(offer["policy"])
    policy["odrl:assigner"] = {"@id": provider["did"]}
    policy["odrl:target"] = {"@id": offer.get("asset_id") or provider["asset_id"]}

    payload = {
        "@context": {
            "@vocab": "https://w3id.org/edc/v0.0.1/ns/",
            "odrl": "http://www.w3.org/ns/odrl/2/",
        },
        "@type": "ContractRequest",
        "counterPartyId": provider["did"],
        "counterPartyAddress": provider["address"],
        "protocol": "dataspace-protocol-http",
        "policy": policy,
    }

    return request_json(
        "POST",
        f"{CONSUMER_MGMT}/v3/contractnegotiations",
        headers=consumer_headers(),
        json_body=payload,
    )


def poll_contract_negotiation(negotiation_id: str, timeout_seconds: int = 60) -> dict:
    deadline = time.time() + timeout_seconds
    last = {}
    while time.time() < deadline:
        last = request_json(
            "GET",
            f"{CONSUMER_MGMT}/v3/contractnegotiations/{negotiation_id}",
            headers={"X-API-Key": CONSUMER_KEY},
            timeout=15,
        )
        if last.get("state") in {"FINALIZED", "TERMINATED"}:
            return last
        time.sleep(2)
    return last


def start_transfer(provider: dict, agreement_id: str, asset_id: str) -> dict:
    payload = {
        "@context": {
            "@vocab": "https://w3id.org/edc/v0.0.1/ns/",
        },
        "@type": "TransferRequest",
        "counterPartyId": provider["did"],
        "counterPartyAddress": provider["address"],
        "protocol": "dataspace-protocol-http",
        "assetId": asset_id,
        "contractId": agreement_id,
        "transferType": "HttpData-PULL",
    }
    return request_json(
        "POST",
        f"{CONSUMER_MGMT}/v3/transferprocesses",
        headers=consumer_headers(),
        json_body=payload,
    )


def poll_transfer(transfer_id: str, timeout_seconds: int = 60) -> dict:
    deadline = time.time() + timeout_seconds
    last = {}
    while time.time() < deadline:
        last = request_json(
            "GET",
            f"{CONSUMER_MGMT}/v3/transferprocesses/{transfer_id}",
            headers={"X-API-Key": CONSUMER_KEY},
            timeout=15,
        )
        if last.get("state") in {"STARTED", "COMPLETED", "TERMINATED"}:
            return last
        time.sleep(2)
    return last


def request_edr(transfer_id: str) -> dict:
    return request_json(
        "GET",
        f"{CONSUMER_MGMT}/v3/edrs/{transfer_id}/dataaddress",
        headers={"X-API-Key": CONSUMER_KEY},
        timeout=30,
    )


def normalize_public_endpoint(endpoint: str) -> str:
    replacements = {
        "http://provider-dataplane:19294": "http://localhost:19294",
        "http://health-dataplane:19294": "http://localhost:21294",
        "http://health-dataplane:21294": "http://localhost:21294",
        "http://civilguard-dataplane:19294": "http://localhost:22294",
        "http://civilguard-dataplane:22294": "http://localhost:22294",
        "http://consumer-dataplane:29291": "http://localhost:29291",
        "http://consumer-dataplane:29294": "http://localhost:29294",
    }
    normalized = endpoint
    for old, new in replacements.items():
        normalized = normalized.replace(old, new)
    return normalized


def download_data(edr: dict) -> dict:
    endpoint = normalize_public_endpoint(edr.get("endpoint", ""))
    token = edr.get("authorization") or edr.get("authCode")
    if not endpoint or not token:
        raise RuntimeError("El EDR no contiene endpoint o token de autorización")

    try:
        response = requests.get(
            endpoint,
            headers={"Authorization": token},
            timeout=30,
        )
    except requests.RequestException as exc:
        raise HttpRequestError("GET", endpoint, message=str(exc)) from exc

    if not 200 <= response.status_code < 300:
        raise HttpRequestError("GET", endpoint, response.status_code, response.text)

    try:
        body = response.json()
    except ValueError:
        body = {"raw": response.text}

    return {
        "endpoint": endpoint,
        "status_code": response.status_code,
        "body": body,
    }


def reset_manual_state():
    for key in list(st.session_state.keys()):
        if key in MANUAL_KEYS or key.startswith("manual_"):
            del st.session_state[key]


def reset_provider_flow_state():
    for key in (
        "manual_catalog_response",
        "manual_offers",
        "manual_selected_offer",
        "manual_negotiation_id",
        "manual_agreement_id",
        "manual_negotiation_state",
        "manual_transfer_id",
        "manual_transfer_state",
        "manual_edr_response",
        "manual_download_response",
        "manual_error",
    ):
        st.session_state.pop(key, None)


def show_http_error(prefix: str, error: Exception):
    st.session_state.manual_error = str(error)
    st.error(prefix)
    if isinstance(error, HttpRequestError):
        st.caption("La operacion no se pudo completar. Revisa el detalle de la respuesta.")
        if error.body:
            with st.expander("Detalle de la respuesta", expanded=False):
                st.write("El servicio devolvio una respuesta de error gestionada por la UI.")
    else:
        with st.expander("Detalle técnico", expanded=False):
            st.code(str(error), language="text")


def selected_provider():
    key = st.session_state.get("manual_provider", "customs")
    return key, PROVIDERS[key]


def selected_offer_from_state():
    selected = st.session_state.get("manual_selected_offer")
    offers = st.session_state.get("manual_offers", [])
    if isinstance(selected, int) and 0 <= selected < len(offers):
        return offers[selected]
    for offer in offers:
        if offer.get("offer_id") == selected or offer.get("asset_id") == selected:
            return offer
    return None


def status_badge(status: str) -> str:
    if status in {"FINALIZED", "STARTED", "COMPLETED", "SUCCESS", "CLEARED"}:
        return "SUCCESS"
    if status in {"TERMINATED", "ERROR", "FAILED"}:
        return "ERROR"
    return "RUNNING"


def short_value(value, max_length: int = 18) -> str:
    text = str(value or "Pendiente")
    if len(text) <= max_length:
        return text
    return f"{text[:8]}...{text[-6:]}"


def render_copyable_value(label: str, value):
    text = str(value or "")
    with st.expander(label):
        st.code(text or "Pendiente", language="text")


def render_full_value(label: str, value):
    st.caption(label)
    st.code(str(value or "Pendiente"), language="text")


def render_result_card(title: str, status: str, fields: dict, copyable_fields=None, full_fields=None):
    copyable_fields = set(copyable_fields or [])
    full_fields = set(full_fields or [])
    badge = status_badge(status)
    if badge == "SUCCESS":
        st.success(f"{title}: {status}")
    elif badge == "ERROR":
        st.error(f"{title}: {status}")
    else:
        st.info(f"{title}: {status}")

    with st.container(border=True):
        columns = st.columns(min(max(len(fields), 1), 4))
        for column, (label, value) in zip(columns, fields.items()):
            if label in copyable_fields:
                with column:
                    st.metric(label, short_value(value))
                    render_copyable_value("Copiar valor completo", value)
            elif label in full_fields:
                with column:
                    render_full_value(label, value)
            else:
                column.metric(label, str(value or "Pendiente"))


def render_download_card(download_response: dict):
    body = download_response.get("body", {})
    status = body.get("status") if isinstance(body, dict) else "DESCARGADO"
    fields = {
        "Resultado": "Descargado con exito",
        "containerId": body.get("containerId") if isinstance(body, dict) else "N/A",
        "authority": body.get("authority") if isinstance(body, dict) else "N/A",
        "status": status,
    }
    render_result_card("Dato descargado", status or "SUCCESS", fields, full_fields={"authority"})
    st.caption(f"Endpoint usado: `{download_response.get('endpoint')}`")


def main():
    st.set_page_config(page_title="Flujo manual por Provider", layout="wide")
    st.title("Flujo manual por Provider")

    if st.button("Volver al dashboard"):
        st.switch_page("app.py")

    if st.button("Reiniciar flujo manual"):
        reset_manual_state()
        st.rerun()

    provider_key = st.selectbox(
        "Provider",
        list(PROVIDERS.keys()),
        key="manual_provider",
        format_func=lambda key: PROVIDERS[key]["label"],
        on_change=reset_provider_flow_state,
    )
    provider = PROVIDERS[provider_key]

    st.subheader("Provider seleccionado")
    col1, col2, col3 = st.columns(3)
    col1.metric("Nombre", provider["label"])
    col2.caption(f"DSP endpoint: `{provider['address']}`")
    col3.caption(f"Consumer Management API: `{CONSUMER_MGMT}`")
    st.caption(f"Estado actual: {st.session_state.get('manual_transfer_state') or st.session_state.get('manual_negotiation_state') or 'Pendiente'}")

    st.subheader("1. Catálogo")
    if st.button("Pedir catálogo"):
        write_ui_event("manual_catalog", "RUNNING", provider_key, "Solicitando catálogo manual")
        reset_after_catalog_request()
        try:
            with st.spinner("Solicitando catálogo..."):
                catalog = request_catalog(provider)
            st.session_state.manual_catalog_response = catalog
            offers = enrich_offer_policy_ids(provider, extract_offers(catalog))
            st.session_state.manual_offers = offers
            save_json(GENERATED_DIR / f"manual-catalog-{provider_key}.json", catalog)
            write_ui_event(
                "manual_catalog",
                "SUCCESS",
                provider_key,
                "Catálogo manual recibido",
                {"offers": len(offers)},
            )
        except Exception as exc:
            write_ui_event("manual_catalog", "ERROR", provider_key, str(exc))
            show_http_error("No se pudo obtener el catálogo", exc)

    catalog = st.session_state.get("manual_catalog_response")
    if catalog:
        with st.expander("Catálogo JSON completo", expanded=False):
            st.json(catalog)

    st.subheader("2. Ofertas")
    offers = st.session_state.get("manual_offers", [])
    if offers:
        st.caption(f"Ofertas negociables recibidas en el catálogo: {len(offers)}")
        summaries = [summarize_offer(offer) for offer in offers]
        st.dataframe(summaries, use_container_width=True, hide_index=True)
        if not isinstance(st.session_state.get("manual_selected_offer"), int):
            st.session_state.pop("manual_selected_offer", None)
        offer_indexes = list(range(len(offers)))
        selected_offer_index = st.selectbox(
            "Oferta",
            offer_indexes,
            key="manual_selected_offer",
            format_func=lambda index: (
                f"{offers[index].get('asset_id') or f'asset-{index}'}"
                f" - {offers[index].get('contract_definition_id') or 'sin contract definition'}"
            ),
        )
        selected = offers[selected_offer_index]
        st.caption(f"Asset seleccionado: `{selected.get('asset_id')}`")
        st.caption(f"Offer id: `{selected.get('offer_id')}`")
    elif catalog:
        st.error("El catálogo no contiene ofertas válidas para negociar.")
        with st.expander("Diagnóstico del Provider"):
            for message in build_empty_catalog_diagnostics(provider):
                st.warning(message)
    else:
        st.info("Pide el catálogo para ver las ofertas disponibles.")

    if catalog:
        with st.expander("Contract Definitions registradas en el Provider"):
            rows = provider_contract_definition_rows(provider, offers)
            if rows:
                st.dataframe(rows, use_container_width=True, hide_index=True)
            else:
                st.info("No hay Contract Definitions registradas en este Provider.")

    selected_offer = selected_offer_from_state()

    st.subheader("3. Negociación")
    if selected_offer and st.button("Negociar contrato"):
        write_ui_event("manual_contract_negotiation", "RUNNING", provider_key, "Negociando contrato manual")
        try:
            with st.spinner("Negociando contrato..."):
                created = start_contract_negotiation(provider, selected_offer)
                negotiation_id = created.get("@id") or created.get("id")
                if not negotiation_id:
                    raise RuntimeError("La respuesta no contiene negotiation id")
                final = poll_contract_negotiation(negotiation_id)

            agreement_id = final.get("contractAgreementId")
            state = final.get("state")
            st.session_state.manual_negotiation_id = negotiation_id
            st.session_state.manual_agreement_id = agreement_id
            st.session_state.manual_agreement_asset_id = selected_offer.get("asset_id") or provider["asset_id"]
            st.session_state.manual_negotiation_state = state
            save_json(
                GENERATED_DIR / f"manual-negotiation-{provider_key}.json",
                {"created": created, "final": final},
            )

            if state != "FINALIZED":
                raise RuntimeError(f"Negociación no finalizada. Estado: {state}")

            write_ui_event(
                "manual_contract_negotiation",
                "SUCCESS",
                provider_key,
                "Contrato manual finalizado",
                {"agreementId": agreement_id, "negotiationId": negotiation_id},
            )
        except Exception as exc:
            write_ui_event("manual_contract_negotiation", "ERROR", provider_key, str(exc))
            show_http_error("No se pudo negociar el contrato", exc)

    if st.session_state.get("manual_negotiation_id"):
        render_result_card(
            "Negociación de contrato",
            st.session_state.get("manual_negotiation_state"),
            {
                "state": st.session_state.get("manual_negotiation_state"),
                "negotiation id": st.session_state.get("manual_negotiation_id"),
                "agreement id": st.session_state.get("manual_agreement_id"),
                "asset id": st.session_state.get("manual_agreement_asset_id"),
            },
            copyable_fields={"negotiation id", "agreement id"},
            full_fields={"asset id"},
        )

    st.subheader("4. Transferencia")
    agreement_id = st.session_state.get("manual_agreement_id")
    if agreement_id and st.button("Iniciar transferencia"):
        write_ui_event("manual_transfer", "RUNNING", provider_key, "Iniciando transferencia manual")
        try:
            with st.spinner("Iniciando transferencia..."):
                asset_id = st.session_state.get("manual_agreement_asset_id") or provider["asset_id"]
                created = start_transfer(provider, agreement_id, asset_id)
                transfer_id = created.get("@id") or created.get("id")
                if not transfer_id:
                    raise RuntimeError("La respuesta no contiene transfer process id")
                final = poll_transfer(transfer_id)

            state = final.get("state")
            st.session_state.manual_transfer_id = transfer_id
            st.session_state.manual_transfer_state = state
            save_json(
                GENERATED_DIR / f"manual-transfer-{provider_key}.json",
                {"created": created, "final": final},
            )

            if state not in {"STARTED", "COMPLETED"}:
                raise RuntimeError(f"Transferencia no iniciada. Estado: {state}")

            write_ui_event(
                "manual_transfer",
                "SUCCESS",
                provider_key,
                "Transferencia manual iniciada",
                {"transferId": transfer_id, "state": state},
            )
        except Exception as exc:
            write_ui_event("manual_transfer", "ERROR", provider_key, str(exc))
            show_http_error("No se pudo iniciar la transferencia", exc)

    if st.session_state.get("manual_transfer_id"):
        render_result_card(
            "Transferencia",
            st.session_state.get("manual_transfer_state"),
            {
                "state": st.session_state.get("manual_transfer_state"),
                "transfer process id": st.session_state.get("manual_transfer_id"),
            },
            copyable_fields={"transfer process id"},
        )

    st.subheader("5. EDR y descarga")
    transfer_state = st.session_state.get("manual_transfer_state")
    if transfer_state in {"STARTED", "COMPLETED"} and st.button("Obtener EDR y descargar dato"):
        write_ui_event("manual_edr", "RUNNING", provider_key, "Solicitando EDR manual")
        try:
            with st.spinner("Solicitando EDR..."):
                edr = request_edr(st.session_state.manual_transfer_id)
            st.session_state.manual_edr_response = edr
            save_json(GENERATED_DIR / f"manual-edr-{provider_key}.json", edr)
            write_ui_event("manual_edr", "SUCCESS", provider_key, "EDR manual obtenido")

            write_ui_event("manual_download", "RUNNING", provider_key, "Descargando dato manual")
            with st.spinner("Descargando dato..."):
                downloaded = download_data(edr)
            st.session_state.manual_download_response = downloaded
            save_json(GENERATED_DIR / f"manual-downloaded-{provider_key}.json", downloaded["body"])
            write_ui_event(
                "manual_download",
                "SUCCESS",
                provider_key,
                "Dato manual descargado",
                {"endpoint": downloaded["endpoint"]},
            )
        except Exception as exc:
            step = "manual_download" if st.session_state.get("manual_edr_response") else "manual_edr"
            write_ui_event(step, "ERROR", provider_key, str(exc))
            show_http_error("No se pudo obtener el EDR o descargar el dato", exc)

    edr_response = st.session_state.get("manual_edr_response")
    if edr_response:
        render_result_card(
            "EDR obtenido",
            "SUCCESS",
            {
                "auth type": edr_response.get("authType"),
                "endpoint": normalize_public_endpoint(edr_response.get("endpoint", "")),
            },
        )

    download_response = st.session_state.get("manual_download_response")
    if download_response:
        render_download_card(download_response)


if __name__ == "__main__":
    main()
