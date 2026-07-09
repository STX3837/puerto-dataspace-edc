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

La UI bloquea los botones mientras haya una ejecución activa para evitar scripts
solapados. Al lanzar una ejecución desde la UI se reinician los eventos y
artefactos monitorizados.

## Qué muestra

- Resumen superior con estado global, progreso, último evento y timestamp.
- Artefactos visuales: resultado agregado, datos descargados por Provider y EDRs.
- Explicación del paso actual y últimos mensajes del flujo.
- Flujo global y estado por Provider.
- JSON originales y timeline de eventos.

Durante una ejecución activa, la pantalla usa recarga suave cada 1 segundo con
`st.fragment`, sin recargar toda la página.

## Artefactos leídos

```text
resources/generated/ui-events.jsonl
resources/generated/aggregated-clearance-status.json
resources/generated/downloaded-*-clearance.json
resources/generated/edr-*-response.json
```

Si todavía no existen eventos o artefactos, el dashboard muestra `Pendiente` y
permanece operativo.
