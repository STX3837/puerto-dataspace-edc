# Puerto Dataspace EDC

Prototipo de Espacio de Datos portuario construido con Eclipse Dataspace
Components (EDC), Dataspace Protocol (DSP) y Decentralized Claims Protocol
(DCP).

El proyecto representa la autorización de retirada de un contenedor. Un Consumer,
que actúa como empresa transportista, consulta y combina información procedente
de tres Providers:

- **Customs**: autorización aduanera.
- **Health**: inspección sanitaria.
- **CivilGuard**: autorización de Guardia Civil.

El contenedor queda disponible para su retirada únicamente cuando los tres
Providers responden con estado `CLEARED`.

## Arquitectura

```mermaid
flowchart LR
    KCPG[Keycloak PostgreSQL] --> KC[Keycloak<br/>realm logistics-dataspace]
    KC --> CIH[Consumer Identity Hub]
    KC --> PIH1[Customs Identity Hub]
    KC --> PIH2[Health Identity Hub]
    KC --> PIH3[CivilGuard Identity Hub]
    KC --> IS[Issuer Service]

    IS[Issuer Service<br/>MembershipCredential + TransportCompanyCredential] --> CIH
    IS --> PIH1
    IS --> PIH2
    IS --> PIH3

    V[HashiCorp Vault<br/>claves y secretos] --> CCP[Consumer Control Plane]
    V --> CP1[Customs Control Plane]
    V --> CP2[Health Control Plane]
    V --> CP3[CivilGuard Control Plane]
    V --> DP1[Customs Data Plane]
    V --> DP2[Health Data Plane]
    V --> DP3[CivilGuard Data Plane]

    CIH --> CCP
    PIH1 --> CP1
    PIH2 --> CP2
    PIH3 --> CP3

    CCP <-->|DSP + DCP| CP1
    CCP <-->|DSP + DCP| CP2
    CCP <-->|DSP + DCP| CP3

    CP1 --> DP1
    CP2 --> DP2
    CP3 --> DP3

    DP1 --> API[Regulatory Clearance Mock API]
    DP2 --> API
    DP3 --> API

    CCP --> CDP[Consumer Data Plane]
    CDP -. transferencia PULL .-> DP1
    CDP -. transferencia PULL .-> DP2
    CDP -. transferencia PULL .-> DP3
```

Cada participante dispone de un Control Plane, un Data Plane y un Identity Hub
con PostgreSQL independiente. El Issuer Service emite una
`MembershipCredential` para cada participante y una
`TransportCompanyCredential` para el Consumer. Durante catálogo, negociación y
transferencia, DCP utiliza esas credenciales para autenticar y autorizar a las
contrapartes.

## Infraestructura base

La infraestructura común está definida en
[`docker-compose.infra.yml`](docker-compose.infra.yml). Este compose levanta:

- `keycloak-postgres`: base de datos PostgreSQL de Keycloak.
- `keycloak`: servidor Keycloak accesible en `http://localhost:8080`.
- `vault`: HashiCorp Vault en modo desarrollo, accesible en
  `http://localhost:8200`, con token `root`.

Keycloak usa PostgreSQL y arranca con import automático del realm:

```yaml
command: start-dev --import-realm
volumes:
  - ./infra/keycloak/import:/opt/keycloak/data/import
```

El fichero importado es
[`infra/keycloak/import/realm-export.json`](infra/keycloak/import/realm-export.json)
y contiene el realm `logistics-dataspace` con los clients, client scopes,
asociaciones de scopes, roles y secrets de demo necesarios para Identity Hub e
Issuer Service.

Para un usuario nuevo, basta con arrancar la infraestructura desde la raíz del
repositorio:

```powershell
docker compose -f .\docker-compose.infra.yml up -d
```

Para levantar infraestructura y servicios EDC en una sola orden:

```powershell
docker compose -f .\docker-compose.infra.yml -f .\docker-compose.edc.yml up -d
```

> Importante: no ejecutes `docker compose down -v` si quieres conservar datos.
> La opción `-v` elimina volúmenes, incluido el PostgreSQL de Keycloak y las
> bases de datos del proyecto.

## Participantes

| Participante | DID | Asset |
|---|---|---|
| Consumer | `did:web:consumer-identityhub%3A7083:consumer` | Consume y agrega los tres resultados |
| Customs | `did:web:provider-identityhub%3A8183:provider` | `asset-clearance-mscu7654321` |
| Health | `did:web:health-identityhub%3A8183:health` | `asset-health-clearance-mscu7654321` |
| CivilGuard | `did:web:civilguard-identityhub%3A8183:civilguard` | `asset-civilguard-clearance-mscu7654321` |
| Issuer | `did:web:issuer-service%3A10016:issuer` | Emite `MembershipCredential` y `TransportCompanyCredential` |

## Puertos principales

| Stack | Identity Hub | Management API | DSP | Control API | Data Plane publico | PostgreSQL |
|---|---:|---:|---:|---:|---:|---:|
| Consumer | `7280-7284` | `29193` | `29292` | `29194` | `29294` | `7433` |
| Customs | `7180-7184` | `19193` | `19292` | `19194` | `19294` | `7432` |
| Health | `7380-7384` | `21193` | `21292` | `21194` | `21294` | `7434` |
| CivilGuard | `7480-7484` | `22193` | `22292` | `22194` | `22294` | `7435` |

Otros servicios:

| Servicio | Puertos |
|---|---|
| Regulatory Clearance Mock API | `8081` |
| Keycloak | `8080` |
| Keycloak PostgreSQL | `5432` |
| HashiCorp Vault | `8200` |
| Issuer Service | `10010`, `10011`, `10012`, `10013`, `10015`, `10016`, `9999` |
| Issuer PostgreSQL | `7444` |

La infraestructura común está en
[`docker-compose.infra.yml`](docker-compose.infra.yml). Los componentes EDC,
Identity Hub, Issuer Service, Mock API y PostgreSQL propios del proyecto están en
[`docker-compose.edc.yml`](docker-compose.edc.yml).

## Usage Policy actual

En el flujo completo, el Consumer solo puede consultar el estado del contenedor
si cumple todas estas condiciones:

- Está autenticado vía DCP frente al Provider.
- Tiene una `MembershipCredential` activa emitida por el Issuer Service.
- Tiene una `TransportCompanyCredential` con `role = TransportCompany`.
- Demuestra una orden de transporte activa para el `containerId` del asset.

El `containerId` se resuelve desde las propiedades del asset. Para la demo, el
contenedor principal es:

```text
MSCU7654321
```

La validación de orden activa se realiza contra el Mock API de regulatory
clearance, que expone datos de demostración para el transportista del Consumer.

## Requisitos

- Windows con Docker Desktop en ejecución.
- Windows PowerShell 5.1 o PowerShell 7.
- Puertos de las tablas anteriores disponibles.
- Imágenes locales del proyecto:

  - `puerto-edc-controlplane:latest`
  - `puerto-edc-dataplane:latest`
  - `puerto-identityhub-mvd:latest`
  - `puerto-issuerservice-mvd:latest`

El realm de Keycloak se importa desde
`infra/keycloak/import/realm-export.json` al arrancar
`docker-compose.infra.yml`. El script de validación crea o repara en Vault las
claves privadas de participantes y las claves `private-key` y `public-key` del
Transfer Proxy cuando no existen. No construye todas las imágenes personalizadas
desde cero, salvo la imagen del Control Plane durante el flujo principal.

Para comprobar rápidamente las dependencias principales:

```powershell
docker image inspect puerto-edc-controlplane:latest | Out-Null
docker image inspect puerto-edc-dataplane:latest | Out-Null
docker image inspect puerto-identityhub-mvd:latest | Out-Null
docker image inspect puerto-issuerservice-mvd:latest | Out-Null

Invoke-WebRequest -UseBasicParsing http://localhost:8200/v1/sys/health
Invoke-WebRequest -UseBasicParsing http://localhost:8080/realms/logistics-dataspace
```

## Arranque recomendado

Desde la raíz del repositorio, arranca primero Keycloak, PostgreSQL de Keycloak
y Vault:

```powershell
docker compose -f .\docker-compose.infra.yml up -d
```

Después ejecuta el flujo completo de provisionado y smoke test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-edc-and-smoke-three-providers.ps1
```

Si quieres dejar el entorno arrancado y provisionado sin ejecutar el smoke test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-edc-three-providers.ps1
```

Este es el comando principal de validación del proyecto. El script
[`start-edc-and-smoke-three-providers.ps1`](start-edc-and-smoke-three-providers.ps1)
realiza automáticamente:

1. Arranque de PostgreSQL de Identity Hubs, PostgreSQL de Issuer Service,
   Identity Hubs, Issuer Service y Mock API.
2. Espera activa hasta que los Identity Hubs y el Issuer Service estén
   disponibles.
3. Obtención de tokens OAuth2 desde Keycloak usando el realm
   `logistics-dataspace`.
4. Activación y, si hace falta, reprovisionado de los participantes.
5. Emisión de las `MembershipCredential` que falten.
6. Registro y emisión de la `TransportCompanyCredential` del Consumer.
7. Construcción de la imagen `puerto-edc-controlplane:latest`.
8. Arranque o recreación de todos los Control Planes y Data Planes.
9. Provisión de las claves del Transfer Proxy en Vault.
10. Registro de assets, policies y contract definitions en los tres Providers.
11. Comprobación de que los tres Data Planes estan `AVAILABLE`.
12. Ejecución de
    [`smoke-test-three-providers.ps1`](smoke-test-three-providers.ps1).

El smoke test solicita los tres catálogos, negocia tres contratos, inicia tres
transferencias `HttpData-PULL`, descarga los datos y genera el resultado
agregado.

Una ejecución correcta termina con:

```text
OK: flujo multi-provider validado
ENTORNO MULTI-PROVIDER VALIDADO
```

El resultado esperado para los datos de demostración es:

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

## Resultados generados

Los artefactos de ejecución se escriben en `resources/generated/`:

- `catalog-*-response.json`: catálogos recibidos.
- `contract-negotiation-request-*.json`: solicitudes de negociación.
- `transfer-request-*.json`: solicitudes de transferencia.
- `edr-*-response.json`: Endpoint Data References.
- `downloaded-*-clearance.json`: datos descargados de cada Provider.
- `aggregated-clearance-status.json`: resultado final consolidado.

## Interfaz visual

El proyecto incluye un dashboard local en Streamlit para seguir visualmente el
flujo del script principal, el arranque sin smoke test y la validación
multi-provider.

Instalación:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r .\ui\requirements.txt
```

Ejecución:

```powershell
streamlit run .\ui\app.py
```

La interfaz ofrece tres acciones:

- **Ejecutar demo completa**: ejecuta
  `start-edc-and-smoke-three-providers.ps1`.
- **Arrancar EDC sin smoke**: ejecuta `start-edc-three-providers.ps1`.
- **Ejecutar solo smoke test**: ejecuta `smoke-test-three-providers.ps1`.
- **Abrir flujo manual por Provider**: abre una página para ejecutar
  manualmente catálogo, selección de oferta, negociación, transferencia, EDR y
  descarga contra un Provider.

Mientras un script está en ejecución, los botones quedan bloqueados para evitar
ejecuciones solapadas. La UI usa recarga suave cada segundo durante la ejecución
y muestra:

- estado global, progreso, último evento y timestamp;
- artefactos visuales y resultado agregado;
- explicación del paso actual y últimos mensajes del flujo;
- flujo global y estado por Provider;
- JSON originales y timeline de eventos.

La página manual requiere que la infraestructura y los servicios EDC estén
levantados previamente. Puede usarse después de **Arrancar EDC sin smoke** o tras
ejecutar `start-edc-three-providers.ps1` desde consola.

La UI lee eventos desde:

```text
resources/generated/ui-events.jsonl
```

y muestra los artefactos generados en:

```text
resources/generated/
```

## Tests unitarios

Los tests unitarios validan la lógica DCP sin necesidad de levantar Docker:

- extracción de scopes DCP para `MembershipCredential` y
  `TransportCompanyCredential`;
- combinación de scopes requeridos y existentes;
- aceptación de una `MembershipCredential` activa;
- validación de `TransportCompanyCredential.role`;
- validación de `TransportOrder.activeForContainer`;
- rechazo de operadores, operands, fechas futuras, credenciales ausentes y
  claims malformados.

Para ejecutarlos en Windows:

```powershell
.\gradlew.bat test
```

En Linux o macOS:

```bash
./gradlew test
```

El workflow de GitHub Actions ejecuta estos tests antes del smoke test y
publica los informes HTML y JUnit como el artefacto `unit-test-reports`.

## Diagnóstico

Estado de la infraestructura base:

```powershell
docker compose -f .\docker-compose.infra.yml ps
```

Estado de los servicios EDC:

```powershell
docker compose -f .\docker-compose.edc.yml ps
```

Estado conjunto de infra + EDC:

```powershell
docker compose -f .\docker-compose.infra.yml -f .\docker-compose.edc.yml ps
```

Logs de componentes habituales:

```powershell
docker logs keycloak --since 10m
docker logs vault --since 10m
docker logs consumer-controlplane --since 10m
docker logs provider-controlplane --since 10m
docker logs health-controlplane --since 10m
docker logs civilguard-controlplane --since 10m
```

Comprobar endpoints básicos:

```powershell
Invoke-WebRequest -UseBasicParsing http://localhost:8080/realms/logistics-dataspace
Invoke-WebRequest -UseBasicParsing http://localhost:8200/v1/sys/health
Invoke-WebRequest -UseBasicParsing http://localhost:7280/api/check/readiness
Invoke-WebRequest -UseBasicParsing http://localhost:10010/api/check/readiness
```

Ejecutar únicamente la validación, sin recrear el stack:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\smoke-test-three-providers.ps1
```

Detener solo los servicios EDC:

```powershell
docker compose -f .\docker-compose.edc.yml down
```

Detener infraestructura y EDC conservando volúmenes:

```powershell
docker compose -f .\docker-compose.infra.yml -f .\docker-compose.edc.yml down
```

No uses `down -v` salvo que quieras borrar de forma explícita el estado
persistido del proyecto.
