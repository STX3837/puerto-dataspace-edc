# Orchestrator API

API local para permitir que la UI Streamlit ejecute scripts del host Windows.
El código, dependencias y documentación viven juntos en `orchestrator_api/` para
mantener un unico paquete Python importable.

## Instalación y arranque recomendado

```powershell
.\scripts\orchestrator-start.ps1 -Background
.\scripts\service-start.ps1
```

También puede ejecutarse en primer plano en una terminal separada:

```powershell
.\scripts\orchestrator-start.ps1
```

Si el puerto `8765` está ocupado, comprueba si ya es el orquestador:

```powershell
Invoke-RestMethod http://localhost:8765/health
```

Si responde, el orquestador ya está activo.

Si Docker indica que ya existe un contenedor `vault`, libera ese nombre:

```powershell
docker stop vault
docker rm vault
.\scripts\service-start.ps1
```

## Endpoints

- `GET /health`
- `GET /commands`
- `POST /commands/{command_name}/run`
- `GET /runs`
- `GET /runs/{run_id}`
- `GET /runs/{run_id}/log`
- `POST /runs/{run_id}/stop`

## Seguridad

Si `ORCHESTRATOR_TOKEN` está definido, enviar:

```text
X-Orchestrator-Token: <token>
```

## Uso con UI Docker

La UI Docker accede al host mediante:

```text
http://host.docker.internal:8765
```

Los logs y metadatos de ejecución se guardan en:

```text
resources/generated/orchestrator-runs/
```
