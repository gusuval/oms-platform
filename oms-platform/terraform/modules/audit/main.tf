# ── Módulo: AUDIT ──────────────────────────────────────────────────
# REG-GDPR-003 — Audit trail inmutable: los Cloud Audit Logs se exportan
# por un sink a un bucket con retention policy de 3 años (append-only:
# ningún objeto se puede borrar ni sobrescribir antes de que venza).

variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "region" {
  type        = string
  description = "Ubicación del bucket (REG-GDPR-001)."
}

variable "env" {
  type        = string
  description = "Entorno (staging | production)."
}

variable "retention_days" {
  type        = number
  description = "Retención mínima de los logs de auditoría (REG-GDPR-003: 3 años)."
  default     = 1095
}

variable "lock_retention" {
  type        = bool
  description = "Bloquea la retention policy. IRREVERSIBLE: el bucket no se podrá borrar hasta que venza el último objeto."
  default     = false
}

variable "labels" {
  type        = map(string)
  description = "Etiquetas comunes."
}

resource "google_storage_bucket" "audit" {
  project                     = var.project_id
  name                        = "${var.project_id}-oms-audit-logs"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  retention_policy {
    retention_period = var.retention_days * 86400
    is_locked        = var.lock_retention
  }

  # Abaratar: pasado un mes casi nadie lee los logs.
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  labels = var.labels

  lifecycle {
    prevent_destroy = true
  }
}

# Activa los Data Access audit logs de los servicios con datos personales.
resource "google_project_iam_audit_config" "data_access" {
  for_each = toset([
    "cloudsql.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ])
  project = var.project_id
  service = each.value

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

resource "google_logging_project_sink" "audit" {
  project                = var.project_id
  name                   = "oms-${var.env}-audit-sink"
  destination            = "storage.googleapis.com/${google_storage_bucket.audit.name}"
  filter                 = "logName:\"cloudaudit.googleapis.com\""
  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.audit.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.audit.writer_identity
}

output "audit_bucket" {
  description = "Bucket con el audit trail inmutable."
  value       = google_storage_bucket.audit.name
}
