# Looker (Google Cloud core) – Private IP with Terraform

[Versión en español](README.es.md)

This Terraform config creates a Looker (Google Cloud core) instance reachable **only over private IP**, using Private Service Access (VPC peering), a custom domain and a private DNS zone.

## What it creates

| Resource | Purpose |
|---|---|
| `google_project_service` | Enables the Looker, Service Networking and Cloud DNS APIs |
| `google_compute_global_address` | Reserved /22 range for Private Service Access |
| `google_service_networking_connection` | VPC peering with Google services |
| `google_looker_instance` | The Looker instance (private IP only, Enterprise edition) |
| `google_dns_managed_zone` + `google_dns_record_set` | Private DNS so the custom domain resolves to the instance's private IP |

## Prerequisites

- A GCP project with billing enabled.
- An existing VPC (default name: `mi-vpc`). To create it with Terraform, replace the `data "google_compute_network"` block with a `resource`.
- An **OAuth client** (type *Web application*) created in the console under *APIs & Services → Credentials*, with this authorized redirect URI:
  `https://<your-custom-domain>/oauth2callback`
- A Looker edition that supports private IP (this config uses `LOOKER_CORE_ENTERPRISE_ANNUAL`).
- Terraform ≥ 1.3 and permissions to manage networking, DNS and Looker in the project.

## Variables

| Name | Default | Description |
|---|---|---|
| `project_id` | – | GCP project ID |
| `region` | `us-central1` | Region for the instance |
| `instance_name` | `mi-looker` | Looker instance name |
| `network_name` | `mi-vpc` | Existing VPC name |
| `custom_domain` | – | e.g. `looker.example.com` |
| `oauth_client_id` | – | OAuth client ID (sensitive) |
| `oauth_client_secret` | – | OAuth client secret (sensitive) |

Pass secrets via environment variables rather than a committed `.tfvars` file:

```bash
export TF_VAR_oauth_client_id="XXX"
export TF_VAR_oauth_client_secret="YYY"
```

## Create

```bash
terraform init
terraform apply \
  -var="project_id=my-project" \
  -var="custom_domain=looker.example.com"
```

Provisioning takes about 40–60 minutes. Outputs:

- `looker_private_ip`: the instance's private IP
- `looker_url`: the URL users open

## Recreate the instance

To replace only the Looker instance while keeping the network and DNS, export the content, replace the instance, then import the content:

```bash
# 1. Export content (requires a KMS key and a GCS bucket)
gcloud looker instances export mi-looker --region=us-central1 \
  --target-gcs-uri=gs://my-bucket/looker-export \
  --kms-key=projects/PROJECT/locations/REGION/keyRings/KR/cryptoKeys/KEY

# 2. Replace the instance
terraform apply -replace=google_looker_instance.looker

# 3. Import content
gcloud looker instances import mi-looker --region=us-central1 \
  --source-gcs-uri=gs://my-bucket/looker-export
```

The DNS record updates automatically if the private IP changes.

## User access

The instance has no public IP, so users reach it from inside the VPC: through VPN, Cloud Interconnect, or a VM or proxy in the network.

## Notes

- The reserved range must be at least /22 and must not overlap existing subnets.
- If the VPC already has a Service Networking peering, add the Looker range to it instead of creating a new connection.
- Flags and edition names change over time; check the [`google_looker_instance` docs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/looker_instance) and `gcloud looker instances --help`.
