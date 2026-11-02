# ── Módulo: NETWORK ────────────────────────────────────────────────
# VPC privada del OMS.
#
# Nota sobre "subredes en 2 zonas": en GCP las subredes son REGIONALES
# (abarcan todas las zonas de europe-west3). La alta disponibilidad
# multi-zona la dan los servicios regionales que viven en ella
# (Cloud SQL REGIONAL, Memorystore STANDARD_HA, Cloud Run). Creamos dos
# subredes con propósitos distintos:
#   - app: egress directo de Cloud Run hacia la VPC (Direct VPC egress)
#   - ops: VMs operativas (bastion, bonus) — aisladas de la de la app
# Sin IPs públicas en compute: la salida a internet va por Cloud NAT.

variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "region" {
  type        = string
  description = "Región de las subredes, router y NAT."
}

variable "env" {
  type        = string
  description = "Entorno (staging | production); prefija los nombres."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR /16 de la VPC; las subredes se derivan con cidrsubnet()."
}

variable "labels" {
  type        = map(string)
  description = "Etiquetas comunes (los recursos de red no admiten labels; se mantiene por homogeneidad)."
  default     = {}
}

# ─── VPC ──────────────────────────────────────────────────────────
resource "google_compute_network" "main" {
  project                 = var.project_id
  name                    = "oms-${var.env}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# ─── Subredes (regionales → cubren todas las zonas) ──────────────
resource "google_compute_subnetwork" "app" {
  project                  = var.project_id
  name                     = "oms-${var.env}-app"
  ip_cidr_range            = cidrsubnet(var.vpc_cidr, 4, 0) # 10.20.0.0/20
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true # APIs de Google sin salir a internet

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "ops" {
  project                  = var.project_id
  name                     = "oms-${var.env}-ops"
  ip_cidr_range            = cidrsubnet(var.vpc_cidr, 4, 1) # 10.20.16.0/20
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true
}

# ─── Private Service Access para Cloud SQL y Memorystore ─────────
# Rango reservado que Google usa para los endpoints privados de los
# servicios gestionados (peering con servicenetworking).
resource "google_compute_global_address" "private_service_range" {
  project       = var.project_id
  name          = "oms-${var.env}-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
}

# ─── Cloud NAT para salida a internet (sin IPs públicas) ─────────
resource "google_compute_router" "main" {
  project = var.project_id
  name    = "oms-${var.env}-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  project                            = var.project_id
  name                               = "oms-${var.env}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ─── Firewall: deny-all de entrada + reglas explícitas ───────────
resource "google_compute_firewall" "deny_all_ingress" {
  project   = var.project_id
  name      = "oms-${var.env}-deny-all-ingress"
  network   = google_compute_network.main.id
  direction = "INGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_internal" {
  project   = var.project_id
  name      = "oms-${var.env}-allow-internal"
  network   = google_compute_network.main.id
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = [var.vpc_cidr]
}

# SSH solo desde Identity-Aware Proxy y solo a VMs con tag "iap-ssh" (bonus bastion).
resource "google_compute_firewall" "allow_iap_ssh" {
  project   = var.project_id
  name      = "oms-${var.env}-allow-iap-ssh"
  network   = google_compute_network.main.id
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"] # rango de IAP TCP forwarding
  target_tags   = ["iap-ssh"]
}

# Health checks de los Google Front Ends (LB) hacia el puerto de la app.
resource "google_compute_firewall" "allow_lb_health_checks" {
  project   = var.project_id
  name      = "oms-${var.env}-allow-lb-hc"
  network   = google_compute_network.main.id
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

# ─── Outputs ──────────────────────────────────────────────────────
output "network_id" {
  description = "ID de la VPC. Depende del peering PSA: quien lo consuma (Cloud SQL, Redis) espera a que exista."
  value       = google_compute_network.main.id
  depends_on  = [google_service_networking_connection.private_vpc_connection]
}

output "network_self_link" {
  description = "Self link de la VPC."
  value       = google_compute_network.main.self_link
}

output "app_subnet_id" {
  description = "ID de la subred de la app (Direct VPC egress de Cloud Run)."
  value       = google_compute_subnetwork.app.id
}

output "ops_subnet_id" {
  description = "ID de la subred operativa (bastion)."
  value       = google_compute_subnetwork.ops.id
}

output "app_subnet_cidr" {
  description = "CIDR de la subred de la app."
  value       = google_compute_subnetwork.app.ip_cidr_range
}
