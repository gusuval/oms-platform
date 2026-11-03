# ── Módulo: IAM ────────────────────────────────────────────────────
# - Service Account del runtime de Cloud Run, con bindings mínimos
#   (cloudsql.client + secretAccessor SOLO sobre sus dos secretos).
# - Workload Identity Federation para que GitHub Actions despliegue
#   SIN claves estáticas (Vídeo 4).
# - Service Account de CI/CD con mínimo privilegio.

variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "project_number" {
  type        = string
  description = "Número del proyecto (para el service agent de Cloud Run)."
}

variable "env" {
  type        = string
  description = "Entorno (staging | production)."
}

variable "github_repository" {
  type        = string
  description = "Repo GitHub autorizado a impersonar el SA de CI/CD (owner/repo)."
}

variable "allowed_refs" {
  type        = list(string)
  description = "Prefijos de git ref desde los que GitHub Actions puede autenticarse (p. ej. refs/tags/v)."
}

variable "secret_names" {
  type        = map(string)
  description = "Secretos que el runtime puede leer: clave estática => nombre completo del secreto (las claves deben conocerse en plan)."
}

variable "artifact_registry_project_id" {
  type        = string
  description = "Proyecto que aloja el Artifact Registry compartido."
}

# ─── SA del runtime de Cloud Run ─────────────────────────────────
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "oms-${var.env}-runtime"
  display_name = "OMS ${var.env} — Cloud Run runtime SA"
  description  = "Identidad del servicio Cloud Run del OMS."
}

resource "google_project_iam_member" "runtime_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Binding a nivel de SECRETO, no de proyecto: el runtime no puede leer
# ningún otro secreto que se cree en el proyecto en el futuro.
resource "google_secret_manager_secret_iam_member" "runtime_accessor" {
  for_each  = var.secret_names
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# ─── Workload Identity Pool + Provider (GitHub OIDC) ─────────────
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-pool-${var.env}"
  display_name              = "GitHub Actions — ${var.env}"
  description               = "Pool para que GHA impersone SAs sin claves estáticas."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
    # Sin allowed_audiences: GCP acepta solo el nombre completo del provider,
    # que es lo que envía google-github-actions/auth por defecto.
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.actor"      = "assertion.actor"
  }

  # 🔒 Solo workflows de ESTE repo y solo desde los refs permitidos del entorno
  # (staging: main + tags v*; production: solo tags v*).
  attribute_condition = format(
    "assertion.repository == '%s' && (%s)",
    var.github_repository,
    join(" || ", [for r in var.allowed_refs : "assertion.ref.startsWith('${r}')"]),
  )
}

# ─── SA que asume el pipeline ─────────────────────────────────────
resource "google_service_account" "cicd" {
  project      = var.project_id
  account_id   = "oms-${var.env}-cicd"
  display_name = "OMS ${var.env} — CI/CD SA (impersonado vía WIF)"
}

resource "google_service_account_iam_member" "cicd_wif" {
  service_account_id = google_service_account.cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# Roles del pipeline (mínimo privilegio, NUNCA owner/editor):
#   run.developer          → desplegar revisiones y mover tráfico
#   compute.networkViewer  → leer la IP del LB para el healthcheck post-deploy
locals {
  cicd_project_roles = [
    "roles/run.developer",
    "roles/compute.networkViewer",
  ]
}

resource "google_project_iam_member" "cicd" {
  for_each = toset(local.cicd_project_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.cicd.email}"
}

# actAs SOLO sobre el SA del runtime (no serviceAccountUser a nivel proyecto).
resource "google_service_account_iam_member" "cicd_act_as_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cicd.email}"
}

# ─── Artifact Registry compartido (mismo SHA en todos los entornos) ──
# El registry vive en artifact_registry_project_id (staging). Desde
# cada entorno:
#   - el service agent de Cloud Run lo puede LEER (pull de la imagen)
#   - solo el CI/CD del proyecto del registry puede ESCRIBIR (build único)
resource "google_project_iam_member" "serverless_agent_ar_reader" {
  project = var.artifact_registry_project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:service-${var.project_number}@serverless-robot-prod.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "cicd_ar_writer" {
  count   = var.artifact_registry_project_id == var.project_id ? 1 : 0
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# ─── Outputs ──────────────────────────────────────────────────────
output "runtime_service_account_email" {
  description = "Email del SA del runtime. Espera a sus bindings: Cloud Run no arranca sin acceso a los secretos."
  value       = google_service_account.runtime.email
  depends_on = [
    google_secret_manager_secret_iam_member.runtime_accessor,
    google_project_iam_member.runtime_sql_client,
  ]
}

output "workload_identity_provider" {
  description = "Provider de WIF para google-github-actions/auth (projects/<NUM>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "cicd_service_account_email" {
  description = "SA que impersona GitHub Actions."
  value       = google_service_account.cicd.email
}
