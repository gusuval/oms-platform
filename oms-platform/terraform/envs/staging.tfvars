# ── Entorno: STAGING ────────────────────────────────────────────────
# Tier reducido, autoscaling mínimo, deletion_protection sigue ACTIVADO
# (es buena práctica protegerlo también en staging).
#
# Diferencias con production.tfvars (todas de capacidad/identidad):
#   project_id, db_tier, redis_memory_size_gb, cloud_run_*, github_allowed_refs

project_id = "gusuval-acme-oms-stg2"
region     = "europe-west3" # REG-GDPR-001
env        = "staging"

vpc_cidr = "10.20.0.0/16"

db_tier              = "db-perf-optimized-N-2" # 2 vCPU (Enterprise Plus, PITR 14 d)
redis_memory_size_gb = 1

cloud_run_min_instances = 0 # escala a cero cuando no hay tráfico
cloud_run_max_instances = 2 # tope conservador para staging
cloud_run_cpu           = "1000m"
cloud_run_memory        = "1Gi"

# Registry compartido: vive en staging; producción tira del MISMO digest.
artifact_registry_project_id = "gusuval-acme-oms-stg2"
image_repo                   = "europe-west3-docker.pkg.dev/gusuval-acme-oms-stg2/oms/oms"
image_sha                    = "" # bootstrap; a partir de ahí despliega Ansible

domain = "" # vacío → <IP-LB>.nip.io

deletion_protection = true # también en staging

github_repository   = "gusuval/oms-platform"
github_allowed_refs = ["refs/heads/main", "refs/tags/v"]
