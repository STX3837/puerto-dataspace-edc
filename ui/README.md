# Demo Monitor Streamlit

Dashboard local para seguir visualmente el flujo multi-provider de
`puerto-dataspace-edc`.

## Instalación

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r .\ui\requirements.txt
```

## Ejecución

```powershell
streamlit run .\ui\app.py
```

## Botones disponibles

- **Ejecutar demo completa**: ejecuta `start-edc-and-smoke-three-providers.ps1`.
- **Arrancar EDC sin smoke**: ejecuta `start-edc-three-providers.ps1`.
- **Ejecutar solo smoke test**: ejecuta `smoke-test-three-providers.ps1`.
- **Abrir flujo manual por Provider**: abre una página para ejecutar paso a paso
  catálogo, selección de oferta, negociación, transferencia, EDR y descarga.

La UI bloquea los botones mientras haya una ejecución activa para evitar scripts
solapados. Al lanzar una ejecución desde la UI se reinician los eventos y
artefactos monitorizados.

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
3. Ver ofertas disponibles y seleccionar una.
4. Negociar contrato hasta `FINALIZED`.
5. Iniciar transferencia hasta `STARTED`.
6. Obtener EDR y descargar el dato.
7. Ver el JSON descargado y guardar artefactos `manual-*.json`.

Antes de usarla, la infraestructura y los servicios EDC deben estar levantados.
Puedes prepararlo con **Arrancar EDC sin smoke** o desde consola:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-edc-three-providers.ps1
```

## Artefactos leídos

```text
resources/generated/ui-events.jsonl
resources/generated/aggregated-clearance-status.json
resources/generated/downloaded-*-clearance.json
resources/generated/edr-*-response.json
resources/generated/manual-*.json
```

Si todavía no existen eventos o artefactos, el dashboard muestra `Pendiente` y
permanece operativo.
