# ── Módulo: DATABASE ───────────────────────────────────────────────
# Cloud SQL PostgreSQL multi-zone (NFR-AVAIL-001) + Memorystore Redis (NFR-PERF-001).
# Las credenciales viven en Secret Manager; la app las recibe como secret refs.

variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "region" {
  type        = string
  description = "Región de Cloud SQL, Redis y réplicas de Secret Manager (REG-GDPR-001)."
}

variable "env" {
  type        = string
  description = "Entorno (staging | production)."
}

variable "network_id" {
  type        = string
  description = "ID de la VPC con Private Service Access ya configurado."
}

variable "db_tier" {
  type        = string
  description = "Tier de Cloud SQL Enterprise Plus (db-perf-optimized-N-*)."
}

variable "db_disk_size_gb" {
  type        = number
  description = "Tamaño inicial del disco (crece solo con disk_autoresize)."
  default     = 100
}

variable "redis_memory_size_gb" {
  type        = number
  description = "Memoria de Memorystore Redis en GB."
}

variable "deletion_protection" {
  type        = bool
  description = "deletion_protection de Cloud SQL (API de GCP)."
}

variable "labels" {
  type        = map(string)
  description = "Etiquetas comunes."
}

# ─── Secret Manager: password de la BD ───────────────────────────
# Replicación user_managed en la región: los secretos no salen de la UE.
resource "google_secret_manager_secret" "db_password" {
  project   = var.project_id
  secret_id = "oms-${var.env}-db-password"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  labels = var.labels
}

resource "random_password" "db" {
  length  = 32
  special = false # evita problemas de escape en DSNs
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

# ─── Cloud SQL PostgreSQL ─────────────────────────────────────────
resource "google_sql_database_instance" "main" {
  project             = var.project_id
  name                = "oms-${var.env}-postgres"
  database_version    = "POSTGRES_16" # pin EXPLÍCITO de versión mayor
  region              = var.region
  deletion_protection = var.deletion_protection

  settings {
    # Enterprise Plus: única edición que permite > 7 días de PITR
    # (OPS-005 pide 14). Exige tiers db-perf-optimized-N-*.
    edition           = "ENTERPRISE_PLUS"
    tier              = var.db_tier
    availability_type = "REGIONAL" # NFR-AVAIL-001: primaria + standby en otra zona
    disk_size         = var.db_disk_size_gb
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    # Encriptación en reposo AES-256 con clave gestionada por Google (NFR-SEC-001).

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 14 # OPS-005: PITR 14 días
      start_time                     = "03:00"
      location                       = var.region # backups dentro de la UE
      backup_retention_settings {
        retained_backups = 14
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # domingo
      hour         = 4
      update_track = "stable"
    }

    ip_configuration {
      ipv4_enabled    = false # nunca expuesto a internet
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000" # queries > 1 s
    }
    database_flags {
      name  = "log_statement"
      value = "ddl"
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false # no guardamos IPs de clientes (GDPR)
    }

    user_labels = var.labels
  }

  lifecycle {
    prevent_destroy = true # defensa extra contra terraform destroy
  }
}

resource "google_sql_database" "oms" {
  project  = var.project_id
  name     = "oms"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "oms" {
  project  = var.project_id
  name     = "oms_app"
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
}

# ─── Memorystore Redis Standard (HA) ──────────────────────────────
resource "google_redis_instance" "cache" {
  project        = var.project_id
  name           = "oms-${var.env}-redis"
  tier           = "STANDARD_HA" # réplica en otra zona con failover automático
  memory_size_gb = var.redis_memory_size_gb
  region         = var.region

  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  redis_version           = "REDIS_7_2"
  transit_encryption_mode = "SERVER_AUTHENTICATION" # TLS en tránsito
  auth_enabled            = true

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 5
        minutes = 0
      }
    }
  }

  labels = var.labels
}

# AUTH string de Redis también en Secret Manager (nunca en env vars en claro).
resource "google_secret_manager_secret" "redis_auth" {
  project   = var.project_id
  secret_id = "oms-${var.env}-redis-auth"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  labels = var.labels
}

resource "google_secret_manager_secret_version" "redis_auth" {
  secret      = google_secret_manager_secret.redis_auth.id
  secret_data = google_redis_instance.cache.auth_string
}

# ─── Outputs ──────────────────────────────────────────────────────
output "db_instance_name" {
  description = "Nombre de la instancia Cloud SQL."
  value       = google_sql_database_instance.main.name
}

output "db_connection_name" {
  description = "Connection name (proyecto:región:instancia) para el conector de Cloud SQL."
  value       = google_sql_database_instance.main.connection_name
}

output "db_private_ip" {
  description = "IP privada de Cloud SQL."
  value       = google_sql_database_instance.main.private_ip_address
}

output "db_name" {
  description = "Nombre de la base de datos de la app."
  value       = google_sql_database.oms.name
}

output "db_user" {
  description = "Usuario de la app en Cloud SQL."
  value       = google_sql_user.oms.name
}

output "db_password_secret_id" {
  description = "secret_id del password de la BD."
  value       = google_secret_manager_secret.db_password.secret_id
}

output "db_password_secret_name" {
  description = "Nombre completo (projects/…/secrets/…) del secreto del password."
  value       = google_secret_manager_secret.db_password.id
}

output "redis_host" {
  description = "IP privada de Memorystore."
  value       = google_redis_instance.cache.host
}

output "redis_port" {
  description = "Puerto de Memorystore."
  value       = google_redis_instance.cache.port
}

output "redis_auth_secret_id" {
  description = "secret_id del AUTH string de Redis."
  value       = google_secret_manager_secret.redis_auth.secret_id
}

output "redis_auth_secret_name" {
  description = "Nombre completo del secreto del AUTH string de Redis."
  value       = google_secret_manager_secret.redis_auth.id
}
