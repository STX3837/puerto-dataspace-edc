from fastapi import FastAPI, HTTPException

app = FastAPI(title="Regulatory Clearance API")

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

@app.get("/health")
def health():
    return {"status": "UP"}

@app.get("/containers/{container_id}/clearance")
def get_clearance_status(container_id: str):
    status = container_status.get(container_id)

    if not status:
        raise HTTPException(status_code=404, detail="Container not found")

    return status

@app.get("/containers/{container_id}/customs-clearance")
def get_customs_clearance_status(container_id: str):
    status = container_customs_status.get(container_id)

    if not status:
        raise HTTPException(status_code=404, detail="Container not found")

    return status

@app.get("/containers/{container_id}/health-inspection")
def get_health_inspection_status(container_id: str):
    status = container_health_status.get(container_id)

    if not status:
        raise HTTPException(status_code=404, detail="Container not found")

    return status

@app.get("/containers/{container_id}/civilguard-clearance")
def get_civilguard_clearance_status(container_id: str):
    status = container_civilguard_status.get(container_id)

    if not status:
        raise HTTPException(status_code=404, detail="Container not found")

    return status

@app.get("/transport-orders/{company_id}/{container_id}/validate")
def validate_transport_order(company_id: str, container_id: str):
    valid = any(
        order["companyId"] == company_id
        and order["containerId"] == container_id
        and order["status"] == "ACTIVE"
        for order in transport_orders
    )

    return {
        "companyId": company_id,
        "containerId": container_id,
        "transportOrderValid": valid
    }