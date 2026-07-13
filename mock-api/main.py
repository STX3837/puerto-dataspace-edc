from datetime import datetime, timezone
import re

from fastapi import FastAPI, HTTPException

app = FastAPI(title="Regulatory Clearance API")

CONTAINER_ID_PATTERN = re.compile(r"^[A-Z]{4}\d{7}$")

container_status = {
    "MSCU1234567": {
        "containerId": "MSCU1234567",
        "customsStatus": "CLEARED",
        "healthInspectionStatus": "PENDING",
        "civilGuardStatus": "CLEARED",
        "overallStatus": "NOT_READY_FOR_PICKUP",
        "blockingAuthority": "HEALTH_INSPECTION",
        "lastUpdatedAt": "2026-06-25T10:30:00Z"
    },
    "MSCU7654321": {
        "containerId": "MSCU7654321",
        "customsStatus": "CLEARED",
        "healthInspectionStatus": "CLEARED",
        "civilGuardStatus": "CLEARED",
        "overallStatus": "READY_FOR_PICKUP",
        "blockingAuthority": None,
        "lastUpdatedAt": "2026-06-25T10:35:00Z"
    }
}

container_customs_status = {
    "MSCU1234567": {
        "containerId": "MSCU1234567",
        "authority": "CUSTOMS",
        "status": "CLEARED",
        "lastUpdatedAt": "2026-06-25T10:30:00Z"
    },
    "MSCU7654321": {
        "containerId": "MSCU7654321",
        "authority": "CUSTOMS",
        "status": "CLEARED",
        "lastUpdatedAt": "2026-06-25T10:35:00Z"
    }
}

container_health_status = {
    "MSCU1234567": {
        "containerId": "MSCU1234567",
        "authority": "HEALTH_INSPECTION",
        "status": "CLEARED",
        "lastUpdatedAt": "2026-06-25T10:30:00Z"
    },
    "MSCU7654321": {
        "containerId": "MSCU7654321",
        "authority": "HEALTH_INSPECTION",
        "status": "PENDING",
        "lastUpdatedAt": "2026-06-25T10:35:00Z"
    }
}

container_civilguard_status = {
    "MSCU1234567": {
        "containerId": "MSCU1234567",
        "authority": "CIVIL_GUARD",
        "status": "CLEARED",
        "lastUpdatedAt": "2026-06-25T10:30:00Z"
    },
    "MSCU7654321": {
        "containerId": "MSCU7654321",
        "authority": "CIVIL_GUARD",
        "status": "CLEARED",
        "lastUpdatedAt": "2026-06-25T10:35:00Z"
    }
}

transport_orders = [
    {
        "transportOrderId": "TO-2026-0001",
        "companyId": "TC-A",
        "containerId": "MSCU1234567",
        "status": "ACTIVE"
    },
    {
        "transportOrderId": "TO-2026-0002",
        "companyId": "TC-A",
        "containerId": "MSCU7654321",
        "status": "ACTIVE"
    }
]

def normalize_container_id(container_id: str) -> str:
    return container_id.strip().upper()


def ensure_valid_container_id(container_id: str) -> str:
    normalized = normalize_container_id(container_id)
    if not CONTAINER_ID_PATTERN.fullmatch(normalized):
        raise HTTPException(
            status_code=400,
            detail="Invalid container id. Expected format: 4 letters followed by 7 digits, for example MSCU7654321.",
        )
    return normalized


def timestamp_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_clearance_status(container_id: str) -> dict:
    return {
        "containerId": container_id,
        "customsStatus": "CLEARED",
        "healthInspectionStatus": "CLEARED",
        "civilGuardStatus": "CLEARED",
        "overallStatus": "READY_FOR_PICKUP",
        "blockingAuthority": None,
        "lastUpdatedAt": timestamp_now()
    }


def default_provider_status(container_id: str, authority: str) -> dict:
    return {
        "containerId": container_id,
        "authority": authority,
        "status": "CLEARED",
        "lastUpdatedAt": timestamp_now()
    }


@app.get("/health")
def health():
    return {"status": "UP"}

@app.get("/containers/{container_id}/clearance")
def get_clearance_status(container_id: str):
    container_id = ensure_valid_container_id(container_id)
    status = container_status.get(container_id)

    if not status:
        return default_clearance_status(container_id)

    return status

@app.get("/containers/{container_id}/customs-clearance")
def get_customs_clearance_status(container_id: str):
    container_id = ensure_valid_container_id(container_id)
    status = container_customs_status.get(container_id)

    if not status:
        return default_provider_status(container_id, "CUSTOMS")

    return status

@app.get("/containers/{container_id}/health-inspection")
def get_health_inspection_status(container_id: str):
    container_id = ensure_valid_container_id(container_id)
    status = container_health_status.get(container_id)

    if not status:
        return default_provider_status(container_id, "HEALTH_INSPECTION")

    return status

@app.get("/containers/{container_id}/civilguard-clearance")
def get_civilguard_clearance_status(container_id: str):
    container_id = ensure_valid_container_id(container_id)
    status = container_civilguard_status.get(container_id)

    if not status:
        return default_provider_status(container_id, "CIVIL_GUARD")

    return status

@app.get("/transport-orders/{company_id}/{container_id}/validate")
def validate_transport_order(company_id: str, container_id: str):
    container_id = ensure_valid_container_id(container_id)
    valid = any(
        order["companyId"] == company_id
        and order["containerId"] == container_id
        and order["status"] == "ACTIVE"
        for order in transport_orders
    )
    if not valid and container_id not in {order["containerId"] for order in transport_orders}:
        valid = True

    return {
        "companyId": company_id,
        "containerId": container_id,
        "transportOrderValid": valid
    }
