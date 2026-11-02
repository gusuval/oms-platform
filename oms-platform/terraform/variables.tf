# Variables del módulo raíz. Se sobreescriben con envs/<env>.tfvars

variable "project_id" {
  type        = string
  description = "ID del proyecto GCP donde se crea la infraestructura."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id no es un ID de proyecto GCP válido (6-30 caracteres, minúsculas, dígitos y guiones)."
  }
}

variable "region" {
  type        = string
  description = "Región principal. REG-GDPR-001 limita a regiones europeas."
  default     = "europe-west3"
  validation {
    condition     = startswith(var.region, "europe-")
    error_message = "REG-GDPR-001 exige una región europea (europe-*)."
  }
}

variable "env" {
  type        = string
  description = "Nombre del entorno: staging | production."
  validation {
    condition     = contains(["staging", "production"], var.env)
    error_message = "env debe ser 'staging' o 'production'."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR /16 de la VPC."
  default     = "10.20.0.0/16"
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr debe ser un CIDR /16 válido."
  }
}

variable "db_tier" {
  type        = string
  description = "Tier de Cloud SQL Enterprise Plus (db-perf-optimized-N-<vCPU>)."
  validation {
    condition     = startswith(var.db_tier, "db-perf-optimized-N-")
    error_message = "Enterprise Plus (necesario para PITR de 14 días) solo admite tiers db-perf-optimized-N-*."
  }
}

variable "redis_memory_size_gb" {
  type        = number
  description = "Memoria de Memorystore Redis en GB."
  default     = 1
}

variable "cloud_run_min_instances" {
  type        = number
  description = "Mínimo de instancias de Cloud Run."
  default     = 0
}

variable "cloud_run_max_instances" {
  type        = number
  description = "Máximo de instancias (NFR-SCAL-001 — pico 5×)."
  default     = 10
}

variable "cloud_run_cpu" {
  type        = string
  description = "Límite de CPU por instancia. Mismo valor que cloud_run_cpu en group_vars de Ansible."
  default     = "1000m"
}

variable "cloud_run_memory" {
  type        = string
  description = "Límite de memoria por instancia. Mismo valor que cloud_run_memory en group_vars de Ansible."
  default     = "1Gi"
}

variable "artifact_registry_project_id" {
  type        = string
  description = "Proyecto que aloja el Artifact Registry compartido (una sola imagen para todos los entornos)."
}

variable "image_repo" {
  type        = string
  description = "Ruta de la imagen en Artifact Registry (europe-west3-docker.pkg.dev/<proj>/oms/oms)."
  validation {
    condition     = can(regex("^europe-[a-z0-9]+-docker\\.pkg\\.dev/[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+$", var.image_repo))
    error_message = "image_repo debe ser <región-europea>-docker.pkg.dev/<proyecto>/<repositorio>/<imagen>."
  }
}

variable "image_sha" {
  type        = string
  description = "Digest de la imagen para la creación inicial (sha256:<64 hex>). Vacío = imagen bootstrap; después la imagen la gestiona Ansible."
  default     = ""
  validation {
    condition     = var.image_sha == "" || can(regex("^sha256:[a-f0-9]{64}$", var.image_sha))
    error_message = "image_sha debe estar vacío o tener formato sha256:<64 caracteres hex>."
  }
}

variable "domain" {
  type        = string
  description = "Dominio público del OMS. Vacío = <IP-del-LB>.nip.io."
  default     = ""
}

variable "deletion_protection" {
  type        = bool
  description = "Habilita deletion_protection en Cloud SQL. SIEMPRE true en producción."
  default     = true
  validation {
    condition     = var.deletion_protection
    error_message = "deletion_protection no se puede desactivar desde tfvars; hazlo a mano y de forma consciente."
  }
}

variable "github_repository" {
  type        = string
  description = "Repo GitHub que puede impersonar el SA vía WIF (formato owner/repo)."
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository debe tener formato owner/repo."
  }
}

variable "github_allowed_refs" {
  type        = list(string)
  description = "Prefijos de git ref autorizados a autenticarse vía WIF en este entorno."
  default     = ["refs/tags/v"]
}

variable "audit_log_retention_days" {
  type        = number
  description = "Retención del audit trail (REG-GDPR-003: mínimo 3 años)."
  default     = 1095
  validation {
    condition     = var.audit_log_retention_days >= 1095
    error_message = "REG-GDPR-003 exige al menos 3 años (1095 días)."
  }
}

variable "lock_audit_retention" {
  type        = bool
  description = "Bloquea (IRREVERSIBLE) la retention policy del bucket de auditoría."
  default     = false
}
