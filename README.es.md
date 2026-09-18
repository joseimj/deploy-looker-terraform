# Looker (Google Cloud core) – IP privada con Terraform

[English version](README.md)

Esta configuración de Terraform crea una instancia de Looker (Google Cloud core) accesible **solo por IP privada**, usando Private Service Access (peering de VPC), un dominio personalizado y una zona DNS privada.

## Qué crea

| Recurso | Propósito |
|---|---|
| `google_project_service` | Habilita las APIs de Looker, Service Networking y Cloud DNS |
| `google_compute_global_address` | Rango /22 reservado para Private Service Access |
| `google_service_networking_connection` | Peering de la VPC con los servicios de Google |
| `google_looker_instance` | La instancia de Looker (solo IP privada, edición Enterprise) |
| `google_dns_managed_zone` + `google_dns_record_set` | DNS privado para que el dominio resuelva a la IP privada de la instancia |

## Prerrequisitos

- Un proyecto de GCP con facturación habilitada.
- Una VPC existente (nombre por defecto: `mi-vpc`). Para crearla con Terraform, reemplaza el bloque `data "google_compute_network"` por un `resource`.
- Un **cliente OAuth** (tipo *Aplicación web*) creado en la consola, en *APIs y servicios → Credenciales*, con este URI de redirección autorizado:
  `https://<tu-dominio>/oauth2callback`
- Una edición de Looker que soporte IP privada (esta configuración usa `LOOKER_CORE_ENTERPRISE_ANNUAL`).
- Terraform ≥ 1.3 y permisos para administrar red, DNS y Looker en el proyecto.

## Variables

| Nombre | Por defecto | Descripción |
|---|---|---|
| `project_id` | – | ID del proyecto de GCP |
| `region` | `us-central1` | Región de la instancia |
| `instance_name` | `mi-looker` | Nombre de la instancia de Looker |
| `network_name` | `mi-vpc` | Nombre de la VPC existente |
| `custom_domain` | – | Ej. `looker.miempresa.com` |
| `oauth_client_id` | – | Client ID de OAuth (sensible) |
| `oauth_client_secret` | – | Client secret de OAuth (sensible) |

Pasa los secretos con variables de entorno, no en un `.tfvars` versionado:

```bash
export TF_VAR_oauth_client_id="XXX"
export TF_VAR_oauth_client_secret="YYY"
```

## Crear

```bash
terraform init
terraform apply \
  -var="project_id=mi-proyecto" \
  -var="custom_domain=looker.miempresa.com"
```

El aprovisionamiento tarda unos 40–60 minutos. Salidas:

- `looker_private_ip`: la IP privada de la instancia
- `looker_url`: la URL que abren los usuarios

## Recrear la instancia

Para reemplazar solo la instancia y conservar la red y el DNS, exporta el contenido, reemplaza la instancia y luego importa el contenido:

```bash
# 1. Exportar contenido (requiere una llave KMS y un bucket de GCS)
gcloud looker instances export mi-looker --region=us-central1 \
  --target-gcs-uri=gs://mi-bucket/looker-export \
  --kms-key=projects/PROYECTO/locations/REGION/keyRings/KR/cryptoKeys/KEY

# 2. Reemplazar la instancia
terraform apply -replace=google_looker_instance.looker

# 3. Importar contenido
gcloud looker instances import mi-looker --region=us-central1 \
  --source-gcs-uri=gs://mi-bucket/looker-export
```

El registro DNS se actualiza solo si cambia la IP privada.

## Acceso de usuarios

La instancia no tiene IP pública, así que los usuarios entran desde dentro de la VPC: por VPN, Cloud Interconnect o una VM o proxy en la red.

## Notas

- El rango reservado debe ser de al menos /22 y no traslaparse con subredes existentes.
- Si la VPC ya tiene un peering de Service Networking, agrega el rango de Looker a ese peering en lugar de crear una conexión nueva.
- Los flags y los nombres de edición cambian con el tiempo; revisa la [documentación de `google_looker_instance`](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/looker_instance) y `gcloud looker instances --help`.
