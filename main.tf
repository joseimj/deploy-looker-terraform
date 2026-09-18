terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# ---------- Variables ----------
variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}
variable "instance_name" {
  type    = string
  default = "mi-looker"
}
variable "network_name" {
  type    = string
  default = "mi-vpc"
}
variable "custom_domain" {
  type        = string
  description = "Ej: looker.miempresa.com"
}
variable "oauth_client_id" {
  type      = string
  sensitive = true
}
variable "oauth_client_secret" {
  type      = string
  sensitive = true
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------- APIs ----------
resource "google_project_service" "apis" {
  for_each = toset([
    "looker.googleapis.com",
    "servicenetworking.googleapis.com",
    "dns.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# ---------- Red ----------
data "google_compute_network" "vpc" {
  name = var.network_name
}

# Rango reservado para Private Service Access (mínimo /22)
resource "google_compute_global_address" "looker_range" {
  name          = "looker-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 22
  network       = data.google_compute_network.vpc.id
}

# Peering con los servicios de Google
resource "google_service_networking_connection" "psa" {
  network                 = data.google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.looker_range.name]
  depends_on              = [google_project_service.apis]
}

# ---------- Instancia de Looker ----------
resource "google_looker_instance" "looker" {
  name             = var.instance_name
  region           = var.region
  platform_edition = "LOOKER_CORE_ENTERPRISE_ANNUAL"

  private_ip_enabled = true
  public_ip_enabled  = false
  consumer_network   = data.google_compute_network.vpc.id
  reserved_range     = google_compute_global_address.looker_range.name

  oauth_config {
    client_id     = var.oauth_client_id
    client_secret = var.oauth_client_secret
  }

  custom_domain {
    domain = var.custom_domain
  }

  depends_on = [google_service_networking_connection.psa]
}

# ---------- DNS privado ----------
resource "google_dns_managed_zone" "looker" {
  name       = "looker-private-zone"
  dns_name   = "${var.custom_domain}."
  visibility = "private"

  private_visibility_config {
    networks {
      network_url = data.google_compute_network.vpc.id
    }
  }
  depends_on = [google_project_service.apis]
}

resource "google_dns_record_set" "looker" {
  managed_zone = google_dns_managed_zone.looker.name
  name         = "${var.custom_domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_looker_instance.looker.ingress_private_ip]
}

# ---------- Outputs ----------
output "looker_private_ip" {
  value = google_looker_instance.looker.ingress_private_ip
}
output "looker_url" {
  value = "https://${var.custom_domain}"
}
