# Puerto Dataspace EDC

Prototipo de espacio de datos para cadenas logísticas y portuarias usando Eclipse Dataspace Components.

## Caso de uso inicial

Consulta del estado administrativo de un contenedor antes de enviar un camión al puerto.

## Componentes iniciales

- EDC Control Plane
- EDC Data Plane
- Mock Regulatory Clearance API
- Keycloak
- Vault
- PostgreSQL
- MinIO

## Mock API

Endpoint de prueba:

GET /containers/MSCU1234567/clearance

Puerto local:

http://localhost:8081