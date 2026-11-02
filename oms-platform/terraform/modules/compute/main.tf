# ── Módulo: COMPUTE ───────────────────────────────────────────────
# Artifact Registry + Cloud Run (monolito OMS) + HTTPS Load Balancer
# con Cloud CDN y Cloud Armor (WAF).
# Cloud Run es stateless: NFR-SCAL-001 (autoescalado horizontal hasta 5×).

variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "region" {
  type        = string
  description = "Región de Cloud Run y del NEG serverless."
}

variable "env" {
  type        = string
  description = "Entorno (staging | production)."
}

variable "create_artifact_registry" {
  type        = bool
  description = "Crea el Artifact Registry en este proyecto (solo en el entorno que lo aloja)."
}

variable "image_repo" {
  type        = string
  description = "Repositorio de imágenes (europe-west3-docker.pkg.dev/<proj>/oms/oms)."
}

variable "image_sha" {
  type        = string
  description = "Digest a desplegar en la creación inicial. Vacío = imagen bootstrap; luego Ansible gestiona la imagen."
}

variable "bootstrap_image" {
  type        = string
  description = "Imagen pública usada en el primer apply, antes de que exista una imagen del OMS."
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "cloud_run_min_instances" {
  type        = number
  description = "Mínimo de instancias."
}

variable "cloud_run_max_instances" {
  type        = number
  description = "Máximo de instancias (NFR-SCAL-001)."
}

variable "cloud_run_cpu" {
  type        = string
  description = "Límite de CPU por instancia (p. ej. 1000m). Debe coincidir con group_vars de Ansible."
}

variable "cloud_run_memory" {
  type        = string
  description = "Límite de memoria por instancia (p. ej. 1Gi). Debe coincidir con group_vars de Ansible."
}

variable "runtime_service_account" {
  type        = string
  description = "Email del SA con el que corre Cloud Run."
}

variable "network_id" {
  type        = string
  description = "VPC para Direct VPC egress."
}

variable "subnet_id" {
  type        = string
  description = "Subred para Direct VPC egress."
}

variable "db_connection_name" {
  type        = string
  description = "Connection name de Cloud SQL."
}

variable "db_name" {
  type        = string
  description = "Base de datos de la app."
}

variable "db_user" {
  type        = string
  description = "Usuario de la app en Cloud SQL."
}

variable "db_secret_id" {
  type        = string
  description = "secret_id del password de la BD."
}

variable "redis_host" {
  type        = string
  description = "IP privada de Memorystore."
}

variable "redis_port" {
  type        = number
  description = "Puerto de Memorystore."
}

variable "redis_auth_secret_id" {
  type        = string
  description = "secret_id del AUTH string de Redis."
}

variable "domain" {
  type        = string
  description = "Dominio público. Vacío = <IP-del-LB>.nip.io (útil sin DNS propio)."
}

variable "labels" {
  type        = map(string)
  description = "Etiquetas comunes."
}

locals {
  image      = var.image_sha == "" ? var.bootstrap_image : "${var.image_repo}@${var.image_sha}"
  domain     = var.domain != "" ? var.domain : "${google_compute_global_address.lb_ip.address}.nip.io"
  repo_parts = split("/", var.image_repo) # host/proyecto/repositorio/imagen
  ar_repo_id = local.repo_parts[2]
}

# ─── Artifact Registry (compartido entre entornos) ───────────────
resource "google_artifact_registry_repository" "oms" {
  count         = var.create_artifact_registry ? 1 : 0
  project       = var.project_id
  location      = var.region
  repository_id = local.ar_repo_id
  format        = "DOCKER"
  description   = "Imágenes del OMS. Un único build se promociona a todos los entornos por digest."

  docker_config {
    immutable_tags = true # un tag no puede reapuntar a otra imagen
  }

  labels = var.labels
}

# ─── Cloud Run service ────────────────────────────────────────────
resource "google_cloud_run_v2_service" "oms" {
  project  = var.project_id
  name     = "oms-${var.env}"
  location = var.region

  # Solo accesible a través del Load Balancer (pasa por Cloud Armor + CDN).
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = var.runtime_service_account

    scaling {
      min_instance_count = var.cloud_run_min_instances
      max_instance_count = var.cloud_run_max_instances
    }

    # Direct VPC egress: alcanzar Memorystore sin VPC connector.
    vpc_access {
      network_interfaces {
        network    = var.network_id
        subnetwork = var.subnet_id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [var.db_connection_name]
      }
    }

    containers {
      image = local.image

      resources {
        limits = {
          cpu    = var.cloud_run_cpu
          memory = var.cloud_run_memory
        }
        cpu_idle = true
      }

      ports {
        container_port = 8080
      }

      env {
        name  = "ENV"
        value = var.env
      }
      env {
        name  = "DB_INSTANCE"
        value = var.db_connection_name
      }
      env {
        name  = "DB_SOCKET_PATH"
        value = "/cloudsql/${var.db_connection_name}"
      }
      env {
        name  = "DB_NAME"
        value = var.db_name
      }
      env {
        name  = "DB_USER"
        value = var.db_user
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = var.db_secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "REDIS_HOST"
        value = var.redis_host
      }
      env {
        name  = "REDIS_PORT"
        value = tostring(var.redis_port)
      }
      env {
        name  = "REDIS_TLS"
        value = "true"
      }
      env {
        name = "REDIS_AUTH"
        value_source {
          secret_key_ref {
            secret  = var.redis_auth_secret_id
            version = "latest"
          }
        }
      }
      # OPS-007: si Redis no responde, la app sirve desde la BD (fail-open de caché).
      env {
        name  = "CACHE_FAIL_OPEN"
        value = "true"
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        initial_delay_seconds = 0
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 12 # hasta 60 s para arrancar
      }

      liveness_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
        period_seconds    = 30
        timeout_seconds   = 3
        failure_threshold = 3
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = var.labels

  lifecycle {
    # Terraform crea el servicio y su configuración; Ansible despliega
    # imágenes y mueve el tráfico. Ignoramos lo que gestiona Ansible para
    # que `terraform plan` siga limpio tras cada deploy.
    ignore_changes = [
      template[0].containers[0].image,
      template[0].revision,
      template[0].labels,
      template[0].annotations,
      traffic,
      client,
      client_version,
    ]
  }
}

# El LB llama a Cloud Run sin identidad: invoker público, pero el ingress
# restringido hace que la URL *.run.app no sea alcanzable desde internet.
resource "google_cloud_run_v2_service_iam_member" "lb_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.oms.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ─── Cloud Armor (WAF) ────────────────────────────────────────────
resource "google_compute_security_policy" "waf" {
  project     = var.project_id
  name        = "oms-${var.env}-waf"
  description = "WAF del OMS: OWASP preconfigurado + rate limiting por IP."

  rule {
    action      = "deny(403)"
    priority    = 1000
    description = "OWASP: SQL injection"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 1001
    description = "OWASP: XSS"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    action      = "throttle"
    priority    = 2000
    description = "Rate limit: 600 req/min por IP"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
    }
  }

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "Default: permitir"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

# ─── HTTPS Load Balancer + Cloud CDN ──────────────────────────────
# serverless NEG → backend service (CDN + WAF) → URL map → HTTPS proxy → forwarding rule

resource "google_compute_region_network_endpoint_group" "cloud_run_neg" {
  project               = var.project_id
  name                  = "oms-${var.env}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.oms.name
  }
}

resource "google_compute_backend_service" "default" {
  project               = var.project_id
  name                  = "oms-${var.env}-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  enable_cdn            = true
  security_policy       = google_compute_security_policy.waf.id

  backend {
    group = google_compute_region_network_endpoint_group.cloud_run_neg.id
  }

  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC" # solo contenido estático; la API no se cachea
    default_ttl       = 3600
    client_ttl        = 3600
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400

    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = true
    }
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "default" {
  project         = var.project_id
  name            = "oms-${var.env}-url-map"
  default_service = google_compute_backend_service.default.id
}

resource "google_compute_global_address" "lb_ip" {
  project = var.project_id
  name    = "oms-${var.env}-lb-ip"
}

# Certificado gestionado por Google. El nombre lleva un hash del dominio
# para poder reemplazarlo sin cortar el servicio (create_before_destroy).
resource "google_compute_managed_ssl_certificate" "default" {
  project = var.project_id
  name    = "oms-${var.env}-cert-${substr(md5(local.domain), 0, 8)}"

  managed {
    domains = [local.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# NFR-SEC-002: perfil RESTRICTED, TLS 1.2 como mínimo aceptable; los
# clientes modernos negocian TLS 1.3 (el GFE lo prefiere).
resource "google_compute_ssl_policy" "default" {
  project         = var.project_id
  name            = "oms-${var.env}-ssl-policy"
  profile         = "RESTRICTED"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "default" {
  project          = var.project_id
  name             = "oms-${var.env}-https-proxy"
  url_map          = google_compute_url_map.default.id
  ssl_certificates = [google_compute_managed_ssl_certificate.default.id]
  ssl_policy       = google_compute_ssl_policy.default.id
}

resource "google_compute_global_forwarding_rule" "https" {
  project               = var.project_id
  name                  = "oms-${var.env}-https"
  target                = google_compute_target_https_proxy.default.id
  ip_address            = google_compute_global_address.lb_ip.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  labels                = var.labels
}

# HTTP → HTTPS (301)
resource "google_compute_url_map" "http_redirect" {
  project = var.project_id
  name    = "oms-${var.env}-http-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  project = var.project_id
  name    = "oms-${var.env}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  project               = var.project_id
  name                  = "oms-${var.env}-http"
  target                = google_compute_target_http_proxy.redirect.id
  ip_address            = google_compute_global_address.lb_ip.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  labels                = var.labels
}

# ─── Outputs ──────────────────────────────────────────────────────
output "cloud_run_service_name" {
  description = "Nombre del servicio Cloud Run."
  value       = google_cloud_run_v2_service.oms.name
}

output "cloud_run_url" {
  description = "URL *.run.app (solo accesible vía LB por el ingress restringido)."
  value       = google_cloud_run_v2_service.oms.uri
}

output "load_balancer_ip" {
  description = "IP global del Load Balancer."
  value       = google_compute_global_address.lb_ip.address
}

output "public_url" {
  description = "URL pública HTTPS del OMS."
  value       = "https://${local.domain}"
}

output "artifact_registry_url" {
  description = "Ruta de la imagen en Artifact Registry."
  value       = var.image_repo
}
