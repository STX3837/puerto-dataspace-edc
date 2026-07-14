# Demo Monitor Streamlit

Dashboard local para seguir visualmente el flujo multi-provider de
`puerto-dataspace-edc`.

## Instalación

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r .\ui\requirements.txt
```

## Ejecución

```powershell
python -m streamlit run .\ui\app.py
```

## Ejecucion con Docker

La UI puede ejecutarse como contenedor usando el modo servicio:

```powershell
.\scripts\service-start.ps1
```

O manualmente:

```powershell
docker compose -f .\docker-compose.infra.yml -f .\docker-compose.edc.yml -f .\docker-compose.service.yml up -d --build ui
```

La aplicacion queda disponible en:

```text
http://localhost:8501
```

Si el puerto `8501` ya esta ocupado, cambia `UI_PORT` en `.env`, por ejemplo
`UI_PORT=8502`.

## Botones de ejecucion con orquestador

Cuando la UI corre en Docker, los botones que ejecutan scripts requieren la API
orquestadora local.

Terminal 1:

```powershell
.\scripts\orchestrator-start.ps1 -Background
```

Terminal 2:

```powershell
.\scripts\service-start.ps1
```

Abrir:

```text
http://localhost:8501
```

Si `8501` esta ocupado, configurar `UI_PORT` en `.env`.

## Compatibilidad local/Docker

Las paginas `Manual Provider Flow` y `Provider Provisioning` adaptan las URLs
automaticamente para funcionar tanto en local como desde Docker.
Los helpers compartidos están en `ui/common.py`.

## Botones disponibles

- **Ejecutar demo completa**: ejecuta `start-edc-and-smoke-three-providers.ps1`
  mediante el orquestador local cuando la UI corre en Docker.
- **Arrancar EDC sin smoke**: ejecuta `scripts/edc-start.ps1` mediante el
  orquestador local cuando la UI corre en Docker. En modo local equivale a
  preparar el entorno con `start-edc-three-providers.ps1`.
- **Ejecutar solo smoke test**: ejecuta `smoke-test-three-providers.ps1`.
- **Abrir flujo manual por Provider**: abre una página para ejecutar paso a paso
  catálogo, selección de oferta, negociación, transferencia, EDR y descarga.
- **Abrir provisioning de Provider**: abre una página para crear, consultar y
  actualizar o borrar Assets, Policies y Contract Definitions en la Management
  API de cada Provider.

La UI bloquea los botones mientras haya una ejecución activa para evitar scripts
solapados. Al lanzar una ejecución desde la UI se reinician los eventos y
artefactos monitorizados. El dashboard muestra la tabla de runs del orquestador,
pero no muestra el log completo del run en pantalla.

## Qué muestra

### Dashboard principal

- Resumen superior con estado global, progreso, último evento y timestamp.
- Artefactos visuales: resultado agregado, datos descargados por Provider y EDRs.
- Explicación del paso actual y últimos mensajes del flujo.
- Flujo global y estado por Provider.
- JSON originales y timeline de eventos.

Durante una ejecución activa, la pantalla usa recarga suave cada 1 segundo con
`st.fragment`, sin recargar toda la página.

### Flujo manual por Provider

La página **Flujo manual por Provider** permite:

1. Seleccionar `customs`, `health` o `civilguard`.
2. Pedir catálogo al Consumer Management API.
3. Ver ofertas disponibles, con `asset id`, `contract definition id`, `offer id`
   y `policy id` real.
4. Negociar contrato hasta `FINALIZED`.
5. Iniciar transferencia hasta `STARTED`.
6. Obtener EDR y descargar el dato.
7. Ver el JSON descargado y guardar artefactos `manual-*.json`.

El `offer id` es el identificador DSP de la oferta. El `policy id` mostrado es
la Contract Policy real asociada en el Provider. Cuando un mismo Asset aparece
varias veces, la tabla y el desplegable lo diferencian por `contract definition
id`; eso indica que varias Contract Definitions publican el mismo Asset.

Las tarjetas de resultado acortan identificadores largos pero ofrecen un
desplegable para copiarlos completos. El `asset id` de negociación y el campo
`authority` descargado se muestran completos.

Antes de usarla, la infraestructura y los servicios EDC deben estar levantados.
Puedes prepararlo con **Arrancar EDC sin smoke** desde la UI Docker, o desde
consola con el flujo local:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-edc-three-providers.ps1
```

### Provisioning de Provider

La página **Provisioning de Provider** permite:

1. Seleccionar `customs`, `health` o `civilguard`.
2. Construir y revisar el payload de un Asset.
3. Crear, consultar, actualizar o borrar el Asset con la Management API.
4. Construir y revisar una Policy `allow-use`, `transport-company-valid-order`
   o `custom-json`.
5. Crear, consultar, actualizar o borrar la Policy.
6. Construir y revisar una Contract Definition usando desplegables con los
   Assets y Policies disponibles del Provider.
7. Crear, consultar, actualizar o borrar la Contract Definition.
8. Validar el endpoint backend, normalizando
   `http://regulatory-clearance-api:8081` a `http://localhost:8081` para
   pruebas desde el host.
9. Elegir que Asset, Policy, backend endpoint o Contract Definition validar
   desde la sección de resumen/validación.

Las actualizaciones de Asset y Contract Definition usan `PUT` para no borrar
recursos que puedan estar referenciados por acuerdos o negociaciones. Las
Contract Definitions asociadas a un Asset se conservan. Para Policies, EDC no
expone `PUT`; la UI usa `DELETE+POST` y recrea después las Contract Definitions
asociadas con los mismos datos.

La pantalla valida los `Container ID` con el formato `4 letras + 7 digitos`
antes de crear o actualizar Assets y Policies, y también revisa el identificador
incluido en el `Backend endpoint / baseUrl` cuando apunta a `/containers/.../`.
La Mock API devuelve `CLEARED` para contenedores válidos no precargados.

Para crear o actualizar un Asset, el `Container ID` del Asset y el incluido en
el backend endpoint deben coincidir.

El `Container ID` solo es necesario en Policies que restringen por
`TransportOrder.activeForContainer`. Al crear o actualizar una Contract
Definition, la UI valida que el `containerId` del Asset y el de la Contract
Policy seleccionada coincidan. Si la Policy usa `${containerId}`, se considera
compatible porque EDC lo resuelve desde el Asset.

La pantalla guarda payloads y respuestas en `resources/generated` con prefijo
`provider-provisioning-*` y escribe eventos `provider_*` en `ui-events.jsonl`.

## Artefactos leídos

```text
resources/generated/ui-events.jsonl
resources/generated/aggregated-clearance-status.json
resources/generated/downloaded-*-clearance.json
resources/generated/edr-*-response.json
resources/generated/manual-*.json
resources/generated/provider-provisioning-*.json
```

Si todavía no existen eventos o artefactos, el dashboard muestra `Pendiente` y
permanece operativo.
