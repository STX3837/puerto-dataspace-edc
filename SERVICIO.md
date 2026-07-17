# Puerto Dataspace EDC como servicio

Este documento define el contrato operativo del modo servicio local del
proyecto. El servicio empaqueta una demo portuaria de espacio de datos basada en
Eclipse Dataspace Components (EDC), Dataspace Protocol (DSP) y Decentralized
Claims Protocol (DCP) para validar si un contenedor puede retirarse.

El modo servicio usa Docker Compose para levantar la infraestructura, los
participantes EDC y una UI Streamlit. Cuando la UI se ejecuta en Docker, una API
orquestadora local permite lanzar scripts concretos del host Windows sin montar
el Docker socket ni aceptar comandos arbitrarios.

## Qué ofrece

- Un Consumer EDC que consulta datos por DSP/DCP.
- Tres Providers EDC: Customs, Health y CivilGuard.
- Identity Hubs por participante.
- Issuer Service para emitir `MembershipCredential` y
  `TransportCompanyCredential`.
- Keycloak como proveedor OAuth2 del entorno.
- Vault para claves y secretos.
- Mock API regulatoria como backend de datos.
- Dashboard Streamlit para operar y visualizar el flujo.
- API orquestadora local en `orchestrator_api/`.
- Scripts de servicio en `scripts/` y fachada opcional `service.ps1`.

La demo principal usa el contenedor:

```text
MSCU7654321
```

La respuesta agregada esperada es:

```json
{
  "containerId": "MSCU7654321",
  "customsStatus": "CLEARED",
  "healthInspectionStatus": "CLEARED",
  "civilGuardStatus": "CLEARED",
  "overallStatus": "READY_FOR_PICKUP",
  "blockingAuthorities": []
}
```

## Arranque recomendado

Para una demo con UI Docker y botones operativos, arranca primero el
orquestador local y después el servicio:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\orchestrator-start.ps1 -Background
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\service-start.ps1
```

El primer comando deja la API orquestadora en `http://localhost:8765`. El
segundo levanta infraestructura, stack EDC y UI Streamlit mediante:

```powershell
docker compose -f .\docker-compose.infra.yml -f .\docker-compose.edc.yml -f .\docker-compose.service.yml up -d --build
```

La UI queda disponible en `http://localhost:8501`, o en el puerto definido por
`UI_PORT` en `.env`.

## Operación

### Ejecutar flujo completo

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-edc-and-smoke-three-providers.ps1
```

También puede lanzarse desde el botón **Ejecutar demo completa** de la UI cuando
el orquestador local está activo.

### Arrancar EDC sin smoke test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\edc-start.ps1
```

En la UI corresponde al botón **Arrancar EDC sin smoke**.

### Ejecutar solo la validación

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\smoke-test-three-providers.ps1
```

Úsalo cuando el entorno ya esté arrancado y provisionado.

### Consultar estado

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\service-status.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\orchestrator-status.ps1
```

`service-status.ps1` muestra los contenedores Docker Compose.
`orchestrator-status.ps1` comprueba la API orquestadora y lista sus últimos
runs.

### Ver logs

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\service-logs.ps1 ui
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\service-logs.ps1 consumer-controlplane
```

El parámetro corresponde al nombre del contenedor.

### Parar el servicio

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\service-stop.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\orchestrator-stop.ps1
```

La parada conserva volúmenes. No usa `down -v`, por lo que se mantiene el estado
persistido.

## Fachada `service.ps1`

Además de los scripts de `scripts/`, existe una fachada para operaciones
frecuentes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 demo
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 smoke
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 health
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 logs -Service consumer-controlplane -Since 20m
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 ui
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 stop
```

Esta fachada es útil para operación local rápida. Para la UI Docker se mantiene
el patrón recomendado con `scripts\orchestrator-start.ps1` y
`scripts\service-start.ps1`.

## Dashboard

```text
http://localhost:8501
```

Si `8501` está ocupado, configura `UI_PORT` en `.env`, por ejemplo:

```text
UI_PORT=8502
```

El dashboard permite ejecutar la demo mediante el orquestador, arrancar EDC sin
smoke test, repetir la validación, hacer flujo manual por Provider y gestionar
Assets, Policies y Contract Definitions.

Cuando la UI corre dentro de Docker, accede al orquestador del host mediante:

```text
http://host.docker.internal:8765
```

## API orquestadora

La API local escucha por defecto en:

```text
http://localhost:8765
```

Endpoints principales:

| Método | Endpoint |
|---|---|
| `GET` | `/health` |
| `GET` | `/commands` |
| `POST` | `/commands/{command_name}/run` |
| `GET` | `/runs` |
| `GET` | `/runs/{run_id}` |
| `GET` | `/runs/{run_id}/log` |
| `POST` | `/runs/{run_id}/stop` |

Comandos permitidos:

| Comando | Script |
|---|---|
| `service_start` | `scripts/service-start.ps1` |
| `service_stop` | `scripts/service-stop.ps1` |
| `edc_start` | `scripts/edc-start.ps1` |
| `demo_full` | `start-edc-and-smoke-three-providers.ps1` |
| `smoke_only` | `smoke-test-three-providers.ps1` |

Si `ORCHESTRATOR_TOKEN` está definido, las peticiones deben incluir:

```text
X-Orchestrator-Token: <token>
```

## Endpoints principales

| Servicio | URL |
|---|---|
| Dashboard Streamlit | `http://localhost:8501` |
| Orchestrator API | `http://localhost:8765` |
| Keycloak | `http://localhost:8080` |
| Vault | `http://localhost:8200` |
| Mock API | `http://localhost:8081` |
| Consumer Management API | `http://localhost:29193/management` |
| Customs Management API | `http://localhost:19193/management` |
| Health Management API | `http://localhost:21193/management` |
| CivilGuard Management API | `http://localhost:22193/management` |

## Artefactos de salida

El servicio deja evidencias de ejecución en `resources/generated/`:

- `aggregated-clearance-status.json`
- `downloaded-*-clearance.json`
- `edr-*-response.json`
- `catalog-*-response.json`
- `ui-events.jsonl`
- `orchestrator-runs/*.json`
- `orchestrator-runs/*.log`

Estos ficheros sirven como trazabilidad técnica de catálogo, negociación,
transferencia, descarga y agregación final.

## Criterio de servicio listo

El servicio se considera listo cuando:

1. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-edc-and-smoke-three-providers.ps1`
   termina sin errores.
2. La salida muestra `OK: flujo multi-provider validado`.
3. Existe `resources/generated/aggregated-clearance-status.json`.
4. El campo `overallStatus` del resultado agregado es `READY_FOR_PICKUP`.

En modo UI Docker, el mismo criterio aplica si el flujo se lanza desde el botón
**Ejecutar demo completa** con la API orquestadora activa.

## Diagnóstico rápido

Si aparece conflicto con un contenedor `vault` externo:

```powershell
docker stop vault
docker rm vault
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\service-start.ps1
```

Si aparece conflicto con el puerto `8765`:

```powershell
Invoke-RestMethod http://localhost:8765/health
```

Si responde, el orquestador ya está activo y no hace falta arrancarlo otra vez.

Si la UI no puede lanzar scripts, revisa que el orquestador esté activo y que la
URL configurada sea `http://host.docker.internal:8765` desde Docker o
`http://localhost:8765` desde ejecución local.

## Límites de la entrega

Esta encapsulación está orientada a demo local y validación técnica. Los
secretos, tokens y claves incluidos son de desarrollo. Para exponerlo fuera de
un entorno local habría que externalizar secretos, activar HTTPS/DID Web real,
aislar redes, restringir puertos publicados y desplegar imágenes versionadas en
un registry.
