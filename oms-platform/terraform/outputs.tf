output "public_url" {
  description = "URL pública HTTPS del OMS (a través del LB)."
  value       = module.compute.public_url
}

output "load_balancer_ip" {
  description = "IP global del HTTPS Load Balancer (apunta aquí tu registro DNS)."
  value       = module.compute.load_balancer_ip
}

output "cloud_run_service" {
  description = "Nombre del servicio Cloud Run (cloud_run_service en Ansible)."
  value       = module.compute.cloud_run_service_name
}

output "cloud_run_url" {
  description = "URL *.run.app del servicio (no accesible desde internet: ingress solo LB)."
  value       = module.compute.cloud_run_url
}

output "artifact_registry_url" {
  description = "Ruta de la imagen en Artifact Registry (image_repo en Ansible)."
  value       = module.compute.artifact_registry_url
}

output "db_connection_name" {
  description = "Connection name de Cloud SQL (proj:region:instance)."
  value       = module.database.db_connection_name
}

output "db_instance_name" {
  description = "Nombre de la instancia Cloud SQL (para el runbook de restore)."
  value       = module.database.db_instance_name
}

output "secret_manager_db_secret_id" {
  description = "Secreto con el password de la BD."
  value       = module.database.db_password_secret_id
}

output "redis_host" {
  description = "Host privado de Memorystore Redis."
  value       = module.database.redis_host
}

output "runtime_service_account" {
  description = "SA con la que corre Cloud Run."
  value       = module.iam.runtime_service_account_email
}

output "workload_identity_provider" {
  description = "Provider de WIF para configurar en GitHub Actions (variable WIF_PROVIDER_<ENV>)."
  value       = module.iam.workload_identity_provider
}

output "cicd_service_account" {
  description = "Service Account que asumen los workflows de CI/CD (variable CICD_SA_<ENV>)."
  value       = module.iam.cicd_service_account_email
}

output "audit_bucket" {
  description = "Bucket con el audit trail inmutable (REG-GDPR-003)."
  value       = module.audit.audit_bucket
}
