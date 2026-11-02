# Composition root del trabajo final.
# Cada módulo encapsula una capa de la arquitectura del OMS.
# El backend (GCS) está en versions.tf con configuración parcial por entorno.

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = local.common_labels
}

locals {
  common_labels = {
    project    = "oms"
    env        = var.env
    managed_by = "terraform"
    module     = "platform"
  }
}

data "google_project" "current" {
  project_id = var.project_id
}

# ┌─────────────────────────────────────────────────────────┐
# │ APIs del proyecto                                       │
# └─────────────────────────────────────────────────────────┘
# disable_on_destroy = false: un destroy nunca apaga APIs de las que
# dependan otros recursos del proyecto.
resource "google_project_service" "enabled" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "redis.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "sts.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ┌─────────────────────────────────────────────────────────┐
# │ Capa de red                                             │
# └─────────────────────────────────────────────────────────┘
module "network" {
  source = "./modules/network"

  project_id = var.project_id
  region     = var.region
  env        = var.env
  vpc_cidr   = var.vpc_cidr
  labels     = local.common_labels

  depends_on = [google_project_service.enabled]
}

# ┌─────────────────────────────────────────────────────────┐
# │ Capa de datos: Cloud SQL Postgres + Memorystore Redis   │
# └─────────────────────────────────────────────────────────┘
module "database" {
  source = "./modules/database"

  project_id           = var.project_id
  region               = var.region
  env                  = var.env
  network_id           = module.network.network_id
  db_tier              = var.db_tier
  redis_memory_size_gb = var.redis_memory_size_gb
  deletion_protection  = var.deletion_protection
  labels               = local.common_labels

  depends_on = [google_project_service.enabled]
}

# ┌─────────────────────────────────────────────────────────┐
# │ Capa IAM: SAs + bindings + Workload Identity Federation │
# └─────────────────────────────────────────────────────────┘
module "iam" {
  source = "./modules/iam"

  project_id                   = var.project_id
  project_number               = data.google_project.current.number
  env                          = var.env
  github_repository            = var.github_repository
  allowed_refs                 = var.github_allowed_refs
  artifact_registry_project_id = var.artifact_registry_project_id
  secret_names = [
    module.database.db_password_secret_name,
    module.database.redis_auth_secret_name,
  ]

  depends_on = [google_project_service.enabled]
}

# ┌─────────────────────────────────────────────────────────┐
# │ Capa de cómputo: Registry + Cloud Run + LB + CDN + WAF  │
# └─────────────────────────────────────────────────────────┘
module "compute" {
  source = "./modules/compute"

  project_id               = var.project_id
  region                   = var.region
  env                      = var.env
  create_artifact_registry = var.artifact_registry_project_id == var.project_id
  image_repo               = var.image_repo
  image_sha                = var.image_sha
  cloud_run_min_instances  = var.cloud_run_min_instances
  cloud_run_max_instances  = var.cloud_run_max_instances
  cloud_run_cpu            = var.cloud_run_cpu
  cloud_run_memory         = var.cloud_run_memory
  runtime_service_account  = module.iam.runtime_service_account_email
  network_id               = module.network.network_id
  subnet_id                = module.network.app_subnet_id
  db_connection_name       = module.database.db_connection_name
  db_name                  = module.database.db_name
  db_user                  = module.database.db_user
  db_secret_id             = module.database.db_password_secret_id
  redis_host               = module.database.redis_host
  redis_port               = module.database.redis_port
  redis_auth_secret_id     = module.database.redis_auth_secret_id
  domain                   = var.domain
  labels                   = local.common_labels

  depends_on = [google_project_service.enabled]
}

# ┌─────────────────────────────────────────────────────────┐
# │ Audit trail inmutable (REG-GDPR-003)                    │
# └─────────────────────────────────────────────────────────┘
module "audit" {
  source = "./modules/audit"

  project_id     = var.project_id
  region         = var.region
  env            = var.env
  retention_days = var.audit_log_retention_days
  lock_retention = var.lock_audit_retention
  labels         = local.common_labels

  depends_on = [google_project_service.enabled]
}
