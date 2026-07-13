from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
import json
import re

import requests
import streamlit as st


ROOT = Path(__file__).resolve().parents[2]
GENERATED_DIR = ROOT / "resources" / "generated"
POLICY_TEMPLATE = ROOT / "resources" / "policies" / "policy-transport-company-valid-order.json"
EVENTS_FILE = GENERATED_DIR / "ui-events.jsonl"

PROVIDERS = {
    "customs": {
        "label": "Customs",
        "management_url": "http://localhost:19193/management",
        "api_key": "provider-api-key",
        "default_asset_id": "asset-clearance-mscu7654321",
        "default_contract_definition_id": "contract-clearance-mscu7654321",
        "default_endpoint": "http://regulatory-clearance-api:8081/containers/MSCU7654321/customs-clearance",
        "default_name": "Customs clearance MSCU7654321",
        "default_description": "Autorizacion aduanera del contenedor MSCU7654321",
        "default_authority": "CUSTOMS",
    },
    "health": {
        "label": "Health",
        "management_url": "http://localhost:21193/management",
        "api_key": "provider-api-key",
        "default_asset_id": "asset-health-clearance-mscu7654321",
        "default_contract_definition_id": "contract-health-clearance-mscu7654321",
        "default_endpoint": "http://regulatory-clearance-api:8081/containers/MSCU7654321/health-inspection",
        "default_name": "Health clearance MSCU7654321",
        "default_description": "Inspeccion sanitaria del contenedor MSCU7654321",
        "default_authority": "HEALTH_INSPECTION",
    },
    "civilguard": {
        "label": "CivilGuard",
        "management_url": "http://localhost:22193/management",
        "api_key": "provider-api-key",
        "default_asset_id": "asset-civilguard-clearance-mscu7654321",
        "default_contract_definition_id": "contract-civilguard-clearance-mscu7654321",
        "default_endpoint": "http://regulatory-clearance-api:8081/containers/MSCU7654321/civilguard-clearance",
        "default_name": "CivilGuard clearance MSCU7654321",
        "default_description": "Autorizacion Guardia Civil del contenedor MSCU7654321",
        "default_authority": "CIVIL_GUARD",
    },
}

DEFAULT_CONTAINER_ID = "MSCU7654321"
DEFAULT_POLICY_ID = "policy-transport-company-valid-order"
DEFAULT_ACCESS_POLICY_ID = "policy-allow-use"
DEFAULT_ROLE = "TransportCompany"
CONTAINER_ID_PATTERN = re.compile(r"^[A-Z]{4}\d{7}$")
VOCAB_CONTEXT = {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}
EDC_CONTEXT = {
    "@vocab": "https://w3id.org/edc/v0.0.1/ns/",
    "edc": "https://w3id.org/edc/v0.0.1/ns/",
    "odrl": "http://www.w3.org/ns/odrl/2/",
}
ODRL_CONTEXT = {
    "@vocab": "https://w3id.org/edc/v0.0.1/ns/",
    "odrl": "http://www.w3.org/ns/odrl/2/",
}


class HttpRequestError(Exception):
    def __init__(self, method: str, url: str, status_code=None, body="", message=""):
        self.method = method
        self.url = url
        self.status_code = status_code
        self.body = body
        super().__init__(message or f"{method} {url} failed with status {status_code}")


def request_json(method: str, url: str, api_key: str | None = None, json_body=None, timeout=30):
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["X-API-Key"] = api_key

    try:
        response = requests.request(method, url, headers=headers, json=json_body, timeout=timeout)
    except requests.RequestException as exc:
        raise HttpRequestError(method, url, message=str(exc)) from exc

    body_text = response.text
    body = {}
    if body_text:
        try:
            body = response.json()
        except ValueError:
            body = body_text

    result = {
        "status_code": response.status_code,
        "url": url,
        "method": method,
        "body": body,
    }

    if not 200 <= response.status_code < 300:
        raise HttpRequestError(method, url, response.status_code, body_text)

    return result


def friendly_error_message(exc: HttpRequestError, resource: str, action: str) -> str:
    resource_labels = {
        "asset": "Asset",
        "policy": "Policy",
        "contract_definition": "Contract Definition",
        "backend": "backend",
    }
    action_labels = {
        "create": "crear",
        "get": "consultar",
        "delete": "borrar",
        "update": "actualizar",
        "validate": "validar",
    }
    resource_label = resource_labels.get(resource, resource)
    action_label = action_labels.get(action, action)

    if exc.status_code == 400:
        return f"No se pudo {action_label} el {resource_label}: la peticion no es valida."
    if exc.status_code == 401 or exc.status_code == 403:
        return f"No se pudo {action_label} el {resource_label}: revisa la API key del Provider."
    if exc.status_code == 404:
        return f"No se encontro el {resource_label} solicitado."
    if exc.status_code == 409:
        return f"No se pudo {action_label} el {resource_label}: ya existe o hay un conflicto con el estado actual."
    if exc.status_code and exc.status_code >= 500:
        return f"No se pudo {action_label} el {resource_label}: el servicio EDC devolvio un error interno."
    if exc.status_code:
        return f"No se pudo {action_label} el {resource_label}. Revisa el detalle de la respuesta."
    return f"No se pudo conectar con el servicio para {action_label} el {resource_label}."


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


def normalize_backend_url_for_host(url: str) -> str:
    return url.replace("http://regulatory-clearance-api:8081", "http://localhost:8081", 1)


def normalize_container_id(container_id: str) -> str:
    return (container_id or "").strip().upper()


def is_valid_container_id(container_id: str) -> bool:
    return bool(CONTAINER_ID_PATTERN.fullmatch(normalize_container_id(container_id)))


def backend_url_container_id(url: str) -> str:
    match = re.search(r"/containers/([^/]+)/", url or "")
    if not match:
        return ""
    return normalize_container_id(match.group(1))


def render_container_validation(container_id: str, *, label: str = "Container ID") -> bool:
    normalized = normalize_container_id(container_id)
    if is_valid_container_id(normalized):
        if container_id != normalized:
            st.info(f"{label} se usara normalizado como `{normalized}`.")
        return True
    st.error(f"{label} invalido. Usa 4 letras y 7 digitos, por ejemplo `{DEFAULT_CONTAINER_ID}`.")
    return False


def build_asset_payload(
    asset_id: str,
    name: str,
    description: str,
    container_id: str,
    authority: str,
    data_type: str,
    base_url: str,
) -> dict:
    return {
        "@context": EDC_CONTEXT,
        "@id": asset_id,
        "@type": "Asset",
        "properties": {
            "id": asset_id,
            "name": name,
            "description": description,
            "contenttype": "application/json",
            "useCase": "Port Regulatory Clearance",
            "containerId": container_id,
            "authority": authority,
            "dataCategory": "ClearanceStatus",
        },
        "dataAddress": {
            "@type": "DataAddress",
            "type": data_type,
            "baseUrl": base_url,
            "proxyPath": "true",
            "proxyQueryParams": "true",
            "proxyBody": "true",
            "proxyMethod": "true",
        },
    }


def build_allow_use_policy_payload(policy_id: str) -> dict:
    return {
        "@context": ODRL_CONTEXT,
        "@id": policy_id,
        "policy": {
            "@type": "odrl:Set",
            "odrl:permission": [
                {
                    "odrl:action": {
                        "odrl:type": "use",
                    },
                }
            ],
        },
    }


def build_transport_policy_payload(policy_id: str, container_id: str, role: str) -> dict:
    template = load_json(POLICY_TEMPLATE)
    if template:
        payload = deepcopy(template)
        payload["@id"] = policy_id
        permissions = payload.get("policy", {}).get("odrl:permission", [])
        for permission in permissions:
            constraints = permission.get("odrl:constraint", [])
            if isinstance(constraints, dict):
                constraints = [constraints]
                permission["odrl:constraint"] = constraints
            for constraint in constraints:
                left_operand = constraint.get("odrl:leftOperand")
                if left_operand == "TransportCompanyCredential.role":
                    constraint["odrl:rightOperand"] = role
                if left_operand == "TransportOrder.activeForContainer":
                    constraint["odrl:rightOperand"] = container_id
        return payload

    return {
        "@context": ODRL_CONTEXT,
        "@id": policy_id,
        "policy": {
            "@type": "odrl:Set",
            "odrl:permission": [
                {
                    "odrl:action": {
                        "odrl:type": "use",
                    },
                    "odrl:constraint": [
                        {
                            "odrl:leftOperand": "TransportCompanyCredential.role",
                            "odrl:operator": {"@id": "odrl:eq"},
                            "odrl:rightOperand": role,
                        },
                        {
                            "odrl:leftOperand": "TransportOrder.activeForContainer",
                            "odrl:operator": {"@id": "odrl:eq"},
                            "odrl:rightOperand": container_id,
                        },
                    ],
                }
            ],
        },
    }


def build_contract_definition_payload(
    contract_definition_id: str,
    asset_id: str,
    access_policy_id: str,
    contract_policy_id: str,
) -> dict:
    return {
        "@context": EDC_CONTEXT,
        "@id": contract_definition_id,
        "@type": "ContractDefinition",
        "accessPolicyId": access_policy_id,
        "contractPolicyId": contract_policy_id,
        "assetsSelector": [
            {
                "@type": "Criterion",
                "operandLeft": "https://w3id.org/edc/v0.0.1/ns/id",
                "operator": "=",
                "operandRight": asset_id,
            }
        ],
    }


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def value_id(value):
    if isinstance(value, dict):
        return value.get("@id") or value.get("id")
    return value


def normalize_contract_definition_payload(contract_definition: dict) -> dict:
    selectors = as_list(
        contract_definition.get("assetsSelector")
        or contract_definition.get("edc:assetsSelector")
    )
    normalized_selectors = []
    for selector in selectors:
        if not isinstance(selector, dict):
            continue
        normalized_selectors.append(
            {
                "@type": selector.get("@type") or "Criterion",
                "operandLeft": value_id(selector.get("operandLeft") or selector.get("edc:operandLeft")),
                "operator": value_id(selector.get("operator") or selector.get("edc:operator")),
                "operandRight": value_id(selector.get("operandRight") or selector.get("edc:operandRight")),
            }
        )

    return {
        "@context": EDC_CONTEXT,
        "@id": contract_definition.get("@id") or contract_definition.get("id"),
        "@type": "ContractDefinition",
        "accessPolicyId": contract_definition.get("accessPolicyId") or contract_definition.get("edc:accessPolicyId"),
        "contractPolicyId": contract_definition.get("contractPolicyId") or contract_definition.get("edc:contractPolicyId"),
        "assetsSelector": normalized_selectors,
    }


def contract_definition_asset_ids(contract_definition: dict) -> set[str]:
    payload = normalize_contract_definition_payload(contract_definition)
    asset_ids = set()
    for selector in payload.get("assetsSelector", []):
        if selector.get("operandLeft") == "https://w3id.org/edc/v0.0.1/ns/id":
            asset_id = selector.get("operandRight")
            if asset_id:
                asset_ids.add(asset_id)
    return asset_ids


def contract_definition_policy_ids(contract_definition: dict) -> set[str]:
    payload = normalize_contract_definition_payload(contract_definition)
    return {
        policy_id
        for policy_id in (payload.get("accessPolicyId"), payload.get("contractPolicyId"))
        if policy_id
    }


def associated_contract_definitions(provider: dict, *, asset_id: str | None = None, policy_id: str | None = None):
    result = list_contract_definitions(provider)
    associated = []
    for item in response_body_items(result):
        if not isinstance(item, dict):
            continue
        if asset_id and asset_id in contract_definition_asset_ids(item):
            associated.append(normalize_contract_definition_payload(item))
        elif policy_id and policy_id in contract_definition_policy_ids(item):
            associated.append(normalize_contract_definition_payload(item))
    return associated


def delete_contract_definitions(provider: dict, contract_definitions: list[dict]):
    results = []
    for contract_definition in contract_definitions:
        contract_definition_id = contract_definition.get("@id")
        delete_result = delete_contract_definition(provider, contract_definition_id)
        results.append(
            {
                "contractDefinitionId": contract_definition_id,
                "deleted": delete_result,
            }
        )
    return results


def create_contract_definitions(provider: dict, contract_definitions: list[dict]):
    results = []
    for contract_definition in contract_definitions:
        contract_definition_id = contract_definition.get("@id")
        create_result = create_contract_definition(provider, contract_definition)
        results.append(
            {
                "contractDefinitionId": contract_definition_id,
                "created": create_result,
            }
        )
    return results


def create_asset(provider: dict, payload: dict):
    return request_json("POST", f"{provider['management_url']}/v3/assets", provider["api_key"], payload)


def put_asset(provider: dict, payload: dict):
    return request_json("PUT", f"{provider['management_url']}/v3/assets", provider["api_key"], payload)


def get_asset(provider: dict, asset_id: str):
    return request_json("GET", f"{provider['management_url']}/v3/assets/{asset_id}", provider["api_key"])


def delete_asset(provider: dict, asset_id: str):
    return request_json("DELETE", f"{provider['management_url']}/v3/assets/{asset_id}", provider["api_key"])


def update_asset(provider: dict, asset_id: str, payload: dict):
    update_result = put_asset(provider, payload)
    return {
        "status_code": update_result["status_code"],
        "method": "PUT",
        "url": update_result["url"],
        "body": {
            "assetId": asset_id,
            "updated": update_result,
            "associatedContractDefinitions": "preserved",
        },
    }


def create_policy(provider: dict, payload: dict):
    return request_json("POST", f"{provider['management_url']}/v3/policydefinitions", provider["api_key"], payload)


def get_policy(provider: dict, policy_id: str):
    return request_json("GET", f"{provider['management_url']}/v3/policydefinitions/{policy_id}", provider["api_key"])


def delete_policy(provider: dict, policy_id: str):
    return request_json("DELETE", f"{provider['management_url']}/v3/policydefinitions/{policy_id}", provider["api_key"])


def update_policy(provider: dict, policy_id: str, payload: dict):
    contract_definitions = associated_contract_definitions(provider, policy_id=policy_id)
    deleted_contract_definitions = delete_contract_definitions(provider, contract_definitions)
    delete_result = delete_policy(provider, policy_id)
    create_result = create_policy(provider, payload)
    created_contract_definitions = create_contract_definitions(provider, contract_definitions)
    return {
        "status_code": create_result["status_code"],
        "method": "DELETE+POST with associated Contract Definitions",
        "url": create_result["url"],
        "body": {
            "associatedContractDefinitions": {
                "deleted": deleted_contract_definitions,
                "created": created_contract_definitions,
            },
            "deleted": delete_result,
            "created": create_result,
        },
    }


def create_contract_definition(provider: dict, payload: dict):
    return request_json("POST", f"{provider['management_url']}/v3/contractdefinitions", provider["api_key"], payload)


def put_contract_definition(provider: dict, payload: dict):
    return request_json("PUT", f"{provider['management_url']}/v3/contractdefinitions", provider["api_key"], payload)


def query_management_collection(provider: dict, resource: str):
    payload = {
        "@context": VOCAB_CONTEXT,
        "@type": "QuerySpec",
        "offset": 0,
        "limit": 100,
    }
    return request_json(
        "POST",
        f"{provider['management_url']}/v3/{resource}/request",
        provider["api_key"],
        payload,
    )


def list_assets(provider: dict):
    return query_management_collection(provider, "assets")


def list_policies(provider: dict):
    return query_management_collection(provider, "policydefinitions")


def list_contract_definitions(provider: dict):
    return query_management_collection(provider, "contractdefinitions")


def get_contract_definition(provider: dict, contract_definition_id: str):
    return request_json(
        "GET",
        f"{provider['management_url']}/v3/contractdefinitions/{contract_definition_id}",
        provider["api_key"],
    )


def delete_contract_definition(provider: dict, contract_definition_id: str):
    return request_json(
        "DELETE",
        f"{provider['management_url']}/v3/contractdefinitions/{contract_definition_id}",
        provider["api_key"],
    )


def update_contract_definition(provider: dict, contract_definition_id: str, payload: dict):
    update_result = put_contract_definition(provider, payload)
    return {
        "status_code": update_result["status_code"],
        "method": "PUT",
        "url": update_result["url"],
        "body": {
            "contractDefinitionId": contract_definition_id,
            "updated": update_result,
        },
    }


def result_key(provider_key: str, resource: str) -> str:
    return f"provision_{provider_key}_{resource}_result"


def field_key(provider_key: str, field: str) -> str:
    return f"provision_{provider_key}_{field}"


def inventory_key(provider_key: str, resource: str) -> str:
    return f"provision_{provider_key}_{resource}_inventory"


def inventory_error_key(provider_key: str, resource: str) -> str:
    return f"provision_{provider_key}_{resource}_inventory_error"


def artifact_resource_name(resource: str) -> str:
    return resource.replace("_", "-")


def generated_payload_path(provider_key: str, resource: str) -> Path:
    name = artifact_resource_name(resource)
    return GENERATED_DIR / f"provider-provisioning-{provider_key}-{name}-payload.json"


def generated_response_path(provider_key: str, resource: str) -> Path:
    name = artifact_resource_name(resource)
    return GENERATED_DIR / f"provider-provisioning-{provider_key}-{name}-response.json"


def generated_error_path(provider_key: str) -> Path:
    return GENERATED_DIR / f"provider-provisioning-{provider_key}-last-error.json"


def handle_operation(provider_key: str, resource: str, action: str, operation, *args):
    provider = PROVIDERS[provider_key]
    event_step = f"provider_{resource}_{action}"
    write_ui_event(event_step, "RUNNING", f"Ejecutando {resource} {action}", provider_key)
    try:
        result = operation(*args)
        st.session_state[result_key(provider_key, resource)] = {
            "ok": True,
            "title": f"{action.title()} {resource}",
            "message": f"Operacion completada con HTTP {result['status_code']}.",
            "data": result,
        }
        save_json(generated_response_path(provider_key, resource), result)
        write_ui_event(event_step, "SUCCESS", f"{resource} {action} completado", provider_key, result)
    except HttpRequestError as exc:
        message = friendly_error_message(exc, resource, action)
        error_data = {
            "method": exc.method,
            "url": exc.url,
            "status_code": exc.status_code,
            "body": exc.body,
            "message": str(exc),
        }
        st.session_state[result_key(provider_key, resource)] = {
            "ok": False,
            "title": f"{action.title()} {resource}",
            "message": message,
            "data": error_data,
        }
        save_json(generated_error_path(provider_key), error_data)
        write_ui_event(event_step, "ERROR", message, provider_key, error_data)


def render_result(provider_key: str, resource: str):
    result = st.session_state.get(result_key(provider_key, resource))
    if not result:
        return

    if result["ok"]:
        st.success(result["message"])
    else:
        st.error(result["message"])
    with st.expander(f"Detalle: {result['title']}"):
        st.json(result["data"])


def render_payload(title: str, provider_key: str, name: str, payload: dict):
    save_json(generated_payload_path(provider_key, name), payload)
    with st.expander(title):
        st.json(payload)


def response_body_items(result: dict) -> list:
    body = result.get("body", [])
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        for key in ("value", "content", "items", "results", "data"):
            value = body.get(key)
            if isinstance(value, list):
                return value
        return [body]
    return []


def extract_resource_ids(result: dict) -> list[str]:
    ids = []
    for item in response_body_items(result):
        if not isinstance(item, dict):
            continue
        resource_id = item.get("@id") or item.get("id") or item.get("edc:id")
        if resource_id and resource_id not in ids:
            ids.append(resource_id)
    return ids


def extract_backend_urls(result: dict) -> list[str]:
    urls = []
    for item in response_body_items(result):
        if not isinstance(item, dict):
            continue
        data_address = item.get("dataAddress") or item.get("edc:dataAddress") or {}
        if not isinstance(data_address, dict):
            continue
        base_url = data_address.get("baseUrl") or data_address.get("edc:baseUrl")
        if base_url and base_url not in urls:
            urls.append(base_url)
    return urls


def load_provider_inventory(provider_key: str, provider: dict, resource: str, loader):
    try:
        result = loader(provider)
        st.session_state[inventory_key(provider_key, resource)] = extract_resource_ids(result)
        st.session_state[inventory_error_key(provider_key, resource)] = ""
    except HttpRequestError as exc:
        st.session_state[inventory_key(provider_key, resource)] = []
        st.session_state[inventory_error_key(provider_key, resource)] = friendly_error_message(
            exc,
            resource,
            "get",
        )


def ensure_provider_inventory(provider_key: str, provider: dict):
    if inventory_key(provider_key, "asset") not in st.session_state:
        load_provider_inventory(provider_key, provider, "asset", list_assets)
    if inventory_key(provider_key, "policy") not in st.session_state:
        load_provider_inventory(provider_key, provider, "policy", list_policies)
    if inventory_key(provider_key, "contract_definition") not in st.session_state:
        load_provider_inventory(provider_key, provider, "contract_definition", list_contract_definitions)


def load_backend_inventory(provider_key: str, provider: dict):
    try:
        result = list_assets(provider)
        st.session_state[inventory_key(provider_key, "backend")] = extract_backend_urls(result)
        st.session_state[inventory_error_key(provider_key, "backend")] = ""
    except HttpRequestError as exc:
        st.session_state[inventory_key(provider_key, "backend")] = []
        st.session_state[inventory_error_key(provider_key, "backend")] = friendly_error_message(
            exc,
            "backend",
            "get",
        )


def options_with_fallback(options: list[str], *fallbacks: str) -> list[str]:
    merged = [option for option in options if option]
    for fallback in fallbacks:
        if fallback and fallback not in merged:
            merged.append(fallback)
    return merged


def reset_invalid_selectbox_value(key: str, options: list[str]):
    if st.session_state.get(key) not in options:
        st.session_state.pop(key, None)


def set_default_selectbox_value(key: str, options: list[str], preferred: str):
    if key not in st.session_state and preferred in options:
        st.session_state[key] = preferred


def render_inventory_warning(provider_key: str, resource: str):
    message = st.session_state.get(inventory_error_key(provider_key, resource), "")
    if message:
        st.warning(f"No se pudo cargar la lista de {resource}s del Provider. {message}")


def render_provider_summary(provider_key: str, provider: dict):
    cols = st.columns(3)
    cols[0].metric("Provider", provider["label"])
    cols[1].metric("Management API", provider["management_url"])
    cols[2].metric("API Key", provider["api_key"])


def provider_selectbox():
    labels = {key: value["label"] for key, value in PROVIDERS.items()}
    return st.selectbox(
        "Provider",
        list(PROVIDERS.keys()),
        format_func=lambda key: labels[key],
        key="provision_provider",
    )


def render_asset_tab(provider_key: str, provider: dict):
    st.subheader("Asset")
    left, right = st.columns(2)
    asset_id = left.text_input(
        "Asset ID",
        value=provider["default_asset_id"],
        key=field_key(provider_key, "asset_id"),
    )
    name = right.text_input(
        "Nombre",
        value=provider["default_name"],
        key=field_key(provider_key, "asset_name"),
    )
    description = st.text_area(
        "Descripcion",
        value=provider["default_description"],
        key=field_key(provider_key, "asset_description"),
    )
    col1, col2, col3 = st.columns(3)
    container_id_input = col1.text_input(
        "Container ID",
        value=DEFAULT_CONTAINER_ID,
        key=field_key(provider_key, "container_id"),
    )
    container_id = normalize_container_id(container_id_input)
    authority = col2.text_input(
        "Authority",
        value=provider["default_authority"],
        key=field_key(provider_key, "authority"),
    )
    data_type = col3.text_input(
        "Data address type",
        value="HttpData",
        key=field_key(provider_key, "data_type"),
    )
    base_url = st.text_input(
        "Backend endpoint / baseUrl",
        value=provider["default_endpoint"],
        key=field_key(provider_key, "base_url"),
    )
    container_valid = render_container_validation(container_id_input)
    endpoint_container_id = backend_url_container_id(base_url)
    endpoint_valid = True
    if endpoint_container_id and not is_valid_container_id(endpoint_container_id):
        st.error(
            "El containerId del Backend endpoint no es valido. "
            f"Usa 4 letras y 7 digitos, por ejemplo `{DEFAULT_CONTAINER_ID}`."
        )
        endpoint_valid = False
    elif endpoint_container_id and endpoint_container_id != container_id:
        st.warning(
            "El Container ID del Asset y el del Backend endpoint no coinciden: "
            f"`{container_id}` vs `{endpoint_container_id}`."
        )
    can_write_asset = container_valid and endpoint_valid

    payload = build_asset_payload(asset_id, name, description, container_id, authority, data_type, base_url)
    render_payload("Ver payload Asset", provider_key, "asset", payload)

    with st.form(f"asset_create_form_{provider_key}"):
        create_asset_submit = st.form_submit_button("Crear Asset", disabled=not can_write_asset)
    if create_asset_submit:
        handle_operation(provider_key, "asset", "create", create_asset, provider, payload)

    confirm_update = st.checkbox(
        "Confirmo que quiero actualizar este Asset existente",
        key=f"confirm_update_asset_{provider_key}",
    )
    confirm_delete = st.checkbox(
        "Confirmo que quiero borrar este recurso",
        key=f"confirm_delete_asset_{provider_key}",
    )
    col_get, col_update, col_delete = st.columns(3)
    if col_get.button("Ver Asset existente", key=f"get_asset_{provider_key}"):
        handle_operation(provider_key, "asset", "get", get_asset, provider, asset_id)
    if col_update.button(
        "Actualizar Asset existente",
        key=f"update_asset_{provider_key}",
        disabled=not confirm_update or not can_write_asset,
    ):
        handle_operation(provider_key, "asset", "update", update_asset, provider, asset_id, payload)
    if col_delete.button("Borrar Asset", key=f"delete_asset_{provider_key}", disabled=not confirm_delete):
        handle_operation(provider_key, "asset", "delete", delete_asset, provider, asset_id)

    render_result(provider_key, "asset")
    return payload


def render_policy_tab(provider_key: str, provider: dict):
    st.subheader("Policy")
    col1, col2 = st.columns(2)
    policy_id = col1.text_input(
        "Policy ID",
        value=DEFAULT_POLICY_ID,
        key=field_key(provider_key, "policy_id"),
    )
    policy_type = col2.selectbox(
        "Tipo de policy",
        ["transport-company-valid-order", "allow-use", "custom-json"],
        key=field_key(provider_key, "policy_type"),
    )
    col3, col4 = st.columns(2)
    container_id_input = col3.text_input(
        "Container ID",
        value=st.session_state.get(field_key(provider_key, "container_id"), DEFAULT_CONTAINER_ID),
        key=field_key(provider_key, "policy_container_id"),
    )
    container_id = normalize_container_id(container_id_input)
    container_valid = render_container_validation(container_id_input, label="Container ID de la Policy")
    role = col4.text_input(
        "Role requerido",
        value=DEFAULT_ROLE,
        key=field_key(provider_key, "policy_role"),
    )

    if policy_type == "allow-use":
        payload = build_allow_use_policy_payload(policy_id)
    elif policy_type == "custom-json":
        default_payload = build_transport_policy_payload(policy_id, container_id, role)
        custom_text = st.text_area(
            "JSON custom",
            value=json.dumps(default_payload, indent=2, ensure_ascii=False),
            height=320,
            key=field_key(provider_key, "custom_policy_json"),
        )
        try:
            payload = json.loads(custom_text)
        except json.JSONDecodeError as exc:
            st.error(f"JSON invalido: {exc}")
            payload = None
    else:
        payload = build_transport_policy_payload(policy_id, container_id, role)

    if payload:
        render_payload("Ver payload Policy", provider_key, "policy", payload)

    with st.form(f"policy_create_form_{provider_key}"):
        create_policy_submit = st.form_submit_button(
            "Crear Policy",
            disabled=payload is None or not container_valid,
        )
    if create_policy_submit:
        handle_operation(provider_key, "policy", "create", create_policy, provider, payload)

    confirm_delete = st.checkbox(
        "Confirmo que quiero borrar este recurso",
        key=f"confirm_delete_policy_{provider_key}",
    )
    confirm_update = st.checkbox(
        "Confirmo que quiero actualizar esta Policy y recrear sus Contract Definitions asociadas",
        key=f"confirm_update_policy_{provider_key}",
        disabled=payload is None,
    )
    col_get, col_update, col_delete = st.columns(3)
    if col_get.button("Ver Policy existente", key=f"get_policy_{provider_key}"):
        handle_operation(provider_key, "policy", "get", get_policy, provider, policy_id)
    if col_update.button(
        "Actualizar Policy existente",
        key=f"update_policy_{provider_key}",
        disabled=payload is None or not confirm_update or not container_valid,
    ):
        handle_operation(provider_key, "policy", "update", update_policy, provider, policy_id, payload)
    if col_delete.button("Borrar Policy", key=f"delete_policy_{provider_key}", disabled=not confirm_delete):
        handle_operation(provider_key, "policy", "delete", delete_policy, provider, policy_id)

    render_result(provider_key, "policy")
    return payload


def render_contract_definition_tab(provider_key: str, provider: dict):
    st.subheader("Contract Definition")
    ensure_provider_inventory(provider_key, provider)

    if st.button("Actualizar Assets y Policies disponibles", key=f"refresh_contract_inventory_{provider_key}"):
        load_provider_inventory(provider_key, provider, "asset", list_assets)
        load_provider_inventory(provider_key, provider, "policy", list_policies)

    render_inventory_warning(provider_key, "asset")
    render_inventory_warning(provider_key, "policy")

    contract_definition_id = st.text_input(
        "Contract Definition ID",
        value=provider["default_contract_definition_id"],
        key=field_key(provider_key, "contract_definition_id"),
    )
    asset_options = options_with_fallback(
        st.session_state.get(inventory_key(provider_key, "asset"), []),
        st.session_state.get(field_key(provider_key, "asset_id"), ""),
        provider["default_asset_id"],
    )
    policy_options = options_with_fallback(
        st.session_state.get(inventory_key(provider_key, "policy"), []),
        st.session_state.get(field_key(provider_key, "policy_id"), ""),
        DEFAULT_ACCESS_POLICY_ID,
        DEFAULT_POLICY_ID,
    )
    asset_select_key = field_key(provider_key, "contract_asset_id_select")
    access_policy_select_key = field_key(provider_key, "access_policy_id_select")
    contract_policy_select_key = field_key(provider_key, "contract_policy_id_select")
    reset_invalid_selectbox_value(asset_select_key, asset_options)
    reset_invalid_selectbox_value(access_policy_select_key, policy_options)
    reset_invalid_selectbox_value(contract_policy_select_key, policy_options)
    set_default_selectbox_value(access_policy_select_key, policy_options, DEFAULT_ACCESS_POLICY_ID)
    set_default_selectbox_value(contract_policy_select_key, policy_options, DEFAULT_POLICY_ID)

    if st.button("Usar policies recomendadas para publicar en catalogo", key=f"use_recommended_policies_{provider_key}"):
        if DEFAULT_ACCESS_POLICY_ID in policy_options:
            st.session_state[access_policy_select_key] = DEFAULT_ACCESS_POLICY_ID
        if DEFAULT_POLICY_ID in policy_options:
            st.session_state[contract_policy_select_key] = DEFAULT_POLICY_ID
        st.rerun()

    col1, col2, col3 = st.columns(3)
    asset_id = col1.selectbox(
        "Asset ID",
        asset_options,
        key=asset_select_key,
    )
    access_policy_id = col2.selectbox(
        "Access Policy ID",
        policy_options,
        key=access_policy_select_key,
    )
    contract_policy_id = col3.selectbox(
        "Contract Policy ID",
        policy_options,
        key=contract_policy_select_key,
    )

    if access_policy_id != DEFAULT_ACCESS_POLICY_ID:
        st.warning(
            "La Access Policy controla si la oferta aparece en el catalogo. "
            f"Para publicar varias ofertas de forma visible, usa `{DEFAULT_ACCESS_POLICY_ID}` "
            "como Access Policy y deja la politica restrictiva en Contract Policy."
        )

    payload = build_contract_definition_payload(
        contract_definition_id,
        asset_id,
        access_policy_id,
        contract_policy_id,
    )
    render_payload("Ver payload Contract Definition", provider_key, "contract-definition", payload)

    with st.form(f"contract_definition_create_form_{provider_key}"):
        create_contract_submit = st.form_submit_button("Crear Contract Definition")
    if create_contract_submit:
        handle_operation(
            provider_key,
            "contract_definition",
            "create",
            create_contract_definition,
            provider,
            payload,
        )

    confirm_delete = st.checkbox(
        "Confirmo que quiero borrar este recurso",
        key=f"confirm_delete_contract_definition_{provider_key}",
    )
    confirm_update = st.checkbox(
        "Confirmo que quiero actualizar esta Contract Definition si ya existe",
        key=f"confirm_update_contract_definition_{provider_key}",
    )
    col_get, col_update, col_delete = st.columns(3)
    if col_get.button("Ver Contract Definition existente", key=f"get_contract_definition_{provider_key}"):
        handle_operation(
            provider_key,
            "contract_definition",
            "get",
            get_contract_definition,
            provider,
            contract_definition_id,
        )
    if col_update.button(
        "Actualizar Contract Definition existente",
        key=f"update_contract_definition_{provider_key}",
        disabled=not confirm_update,
    ):
        handle_operation(
            provider_key,
            "contract_definition",
            "update",
            update_contract_definition,
            provider,
            contract_definition_id,
            payload,
        )
    if col_delete.button(
        "Borrar Contract Definition",
        key=f"delete_contract_definition_{provider_key}",
        disabled=not confirm_delete,
    ):
        handle_operation(
            provider_key,
            "contract_definition",
            "delete",
            delete_contract_definition,
            provider,
            contract_definition_id,
        )

    render_result(provider_key, "contract_definition")
    return payload


def render_validation_tab(provider_key: str, provider: dict):
    st.subheader("Resumen / Validacion")
    ensure_provider_inventory(provider_key, provider)
    if inventory_key(provider_key, "backend") not in st.session_state:
        load_backend_inventory(provider_key, provider)

    if st.button("Actualizar opciones de validacion", key=f"refresh_validation_inventory_{provider_key}"):
        load_provider_inventory(provider_key, provider, "asset", list_assets)
        load_provider_inventory(provider_key, provider, "policy", list_policies)
        load_provider_inventory(provider_key, provider, "contract_definition", list_contract_definitions)
        load_backend_inventory(provider_key, provider)
        st.rerun()

    render_inventory_warning(provider_key, "asset")
    render_inventory_warning(provider_key, "policy")
    render_inventory_warning(provider_key, "contract_definition")
    render_inventory_warning(provider_key, "backend")

    asset_options = options_with_fallback(
        st.session_state.get(inventory_key(provider_key, "asset"), []),
        st.session_state.get(field_key(provider_key, "asset_id"), ""),
        provider["default_asset_id"],
    )
    policy_options = options_with_fallback(
        st.session_state.get(inventory_key(provider_key, "policy"), []),
        st.session_state.get(field_key(provider_key, "policy_id"), ""),
        DEFAULT_ACCESS_POLICY_ID,
        DEFAULT_POLICY_ID,
    )
    contract_options = options_with_fallback(
        st.session_state.get(inventory_key(provider_key, "contract_definition"), []),
        st.session_state.get(field_key(provider_key, "contract_definition_id"), ""),
        provider["default_contract_definition_id"],
    )
    backend_options = options_with_fallback(
        st.session_state.get(inventory_key(provider_key, "backend"), []),
        st.session_state.get(field_key(provider_key, "base_url"), ""),
        provider["default_endpoint"],
    )

    validation_asset_key = field_key(provider_key, "validation_asset_id")
    validation_policy_key = field_key(provider_key, "validation_policy_id")
    validation_backend_key = field_key(provider_key, "validation_backend_url")
    validation_contract_key = field_key(provider_key, "validation_contract_definition_id")
    reset_invalid_selectbox_value(validation_asset_key, asset_options)
    reset_invalid_selectbox_value(validation_policy_key, policy_options)
    reset_invalid_selectbox_value(validation_backend_key, backend_options)
    reset_invalid_selectbox_value(validation_contract_key, contract_options)

    col_asset, col_policy = st.columns(2)
    asset_id = col_asset.selectbox(
        "Asset a validar",
        asset_options,
        key=validation_asset_key,
    )
    policy_id = col_policy.selectbox(
        "Policy a validar",
        policy_options,
        key=validation_policy_key,
    )
    col_backend, col_contract = st.columns(2)
    base_url = col_backend.selectbox(
        "Backend endpoint a validar",
        backend_options,
        key=validation_backend_key,
    )
    contract_definition_id = col_contract.selectbox(
        "Contract Definition a validar",
        contract_options,
        key=validation_contract_key,
    )

    rows = [
        {"Campo": "Provider seleccionado", "Valor": provider["label"]},
        {"Campo": "Asset ID", "Valor": asset_id},
        {"Campo": "Policy ID", "Valor": policy_id},
        {"Campo": "Contract Definition ID", "Valor": contract_definition_id},
        {"Campo": "Backend endpoint", "Valor": base_url},
    ]
    st.dataframe(rows, use_container_width=True, hide_index=True)

    normalized_url = normalize_backend_url_for_host(base_url)
    st.caption(f"URL para validar desde host: {normalized_url}")

    col1, col2, col3, col4 = st.columns(4)
    if col1.button("Validar backend endpoint", key=f"validate_backend_{provider_key}"):
        handle_operation(
            provider_key,
            "backend",
            "validate",
            lambda: request_json("GET", normalized_url, timeout=10),
        )
    if col2.button("Validar Asset en Management API", key=f"validate_asset_{provider_key}"):
        handle_operation(provider_key, "asset", "validate", get_asset, provider, asset_id)
    if col3.button("Validar Policy en Management API", key=f"validate_policy_{provider_key}"):
        handle_operation(provider_key, "policy", "validate", get_policy, provider, policy_id)
    if col4.button("Validar Contract Definition en Management API", key=f"validate_contract_{provider_key}"):
        handle_operation(
            provider_key,
            "contract_definition",
            "validate",
            get_contract_definition,
            provider,
            contract_definition_id,
        )

    render_result(provider_key, "backend")
    render_result(provider_key, "asset")
    render_result(provider_key, "policy")
    render_result(provider_key, "contract_definition")


def main():
    st.set_page_config(page_title="Provisioning de Provider", layout="wide")
    st.title("Provisioning de Provider")
    st.caption("Crea, consulta y borra Assets, Policies y Contract Definitions desde la Management API.")

    provider_key = provider_selectbox()
    provider = PROVIDERS[provider_key]
    render_provider_summary(provider_key, provider)

    asset_tab, policy_tab, contract_tab, validation_tab = st.tabs(
        ["Asset", "Policy", "Contract Definition", "Resumen / Validacion"]
    )

    with asset_tab:
        render_asset_tab(provider_key, provider)
    with policy_tab:
        render_policy_tab(provider_key, provider)
    with contract_tab:
        render_contract_definition_tab(provider_key, provider)
    with validation_tab:
        render_validation_tab(provider_key, provider)


if __name__ == "__main__":
    main()
