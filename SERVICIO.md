# Puerto Dataspace EDC como servicio

Este proyecto se puede entregar como un servicio demostrador local de espacio de
datos para validar la retirada de contenedores en un entorno portuario. El modo
servicio se apoya en Docker Compose, una UI Streamlit contenedorizada y una API
orquestadora local que permite a la UI lanzar scripts del host Windows sin
montar el Docker socket ni aceptar comandos arbitrarios.

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
- API orquestadora local en `orchestrator_api/` para ejecutar solo comandos
  permitidos desde la UI Docker.

El resultado funcional del servicio es responder si un contenedor está listo
para retirada. Para la demo principal se usa:

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

## Contrato operativo

### Arranque recomendado

```powershell
.\scripts\orchestrator-start.ps1 -Background
.\scripts\service-start.ps1
```

El primer comando deja la API orquestadora disponible en
`http://localhost:8765`. El segundo levanta infraestructura, stack EDC y UI
Streamlit mediante:

```powershell
docker compose -f .\docker-compose.infra.yml -f .\docker-compose.edc.yml -f .\docker-compose.service.yml up -d --build
```

La UI queda disponible en `http://localhost:8501`, o en el puerto definido por
`UI_PORT` en `.env`.

### Arrancar y validar extremo a extremo

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-edc-and-smoke-three-providers.ps1
```

También puede lanzarse desde el botón **Ejecutar demo completa** de la UI cuando
el orquestador local esta activo.

### Ejecutar solo la validacion

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\smoke-test-three-providers.ps1
```

Úsalo cuando el entorno ya esté arrancado y provisionado.

### Consultar estado

```powershell
.\scripts\service-status.ps1
.\scripts\orchestrator-status.ps1
```

`service-status.ps1` muestra el estado de contenedores Docker Compose.
`orchestrator-status.ps1` comprueba la API orquestadora y lista sus últimos runs.

### Ver logs

```powershell
.\scripts\service-logs.ps1 ui
.\scripts\service-logs.ps1 consumer-controlplane
```

El parámetro `-Service` corresponde al nombre del contenedor.

### Abrir dashboard

```text
http://localhost:8501
```

Si `8501` esta ocupado, configura `UI_PORT` en `.env`, por ejemplo
`UI_PORT=8502`.

El dashboard permite ejecutar la demo mediante el orquestador, arrancar EDC sin
smoke test, repetir la validación, hacer flujo manual por Provider y gestionar
Assets, Policies y Contract Definitions.

### Parar el servicio

```powershell
.\scripts\service-stop.ps1
.\scripts\orchestrator-stop.ps1
```

Detiene los contenedores sin borrar volúmenes. No usa `down -v`, por lo que se
conserva el estado persistido.

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

En modo UI Docker, el mismo criterio aplica si el flujo se lanza desde el boton
**Ejecutar demo completa** con la API orquestadora activa.

## Diagnostico rapido

Si aparece conflicto con un contenedor `vault` externo:

```powershell
docker stop vault
docker rm vault
.\scripts\service-start.ps1
```

Si aparece conflicto con el puerto `8765`:

```powershell
Invoke-RestMethod http://localhost:8765/health
```

Si responde, el orquestador ya está activo.

## Límites de la entrega

Esta encapsulación está orientada a demo local y validación técnica. Los
secretos, tokens y claves incluidos son de desarrollo. Para exponerlo fuera de
un entorno local habría que externalizar secretos, activar HTTPS/DID Web real,
aislar redes, restringir puertos publicados y desplegar imágenes versionadas en
un registry.
