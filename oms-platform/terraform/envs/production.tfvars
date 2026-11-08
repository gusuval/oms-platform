# ── Entorno: PRODUCTION ─────────────────────────────────────────────
# Tier mayor, autoscaling con piso mínimo > 0 (latencia consistente),
# deletion_protection OBLIGATORIO.
#
# ⚠ La ÚNICA diferencia legítima respecto a staging.tfvars debería ser:
#    - project_id (otro proyecto)
#    - db_tier / redis_memory_size_gb (más capacidad)
#    - cloud_run_* (más réplicas y recursos)
#    - github_allowed_refs (a producción solo llegan tags de release)
# La imagen es la MISMA: mismo image_repo y el digest lo promociona Ansible.

project_id = "gusuval-acme-oms-prod"
region     = "europe-west3" # REG-GDPR-001
env        = "production"

vpc_cidr = "10.20.0.0/16"

db_tier              = "db-perf-optimized-N-4" # 4 vCPU (Enterprise Plus, PITR 14 d)
redis_memory_size_gb = 5

cloud_run_min_instances = 5  # nunca a cero: latencia consistente
cloud_run_max_instances = 25 # NFR-SCAL-001: pico 5× del normal
cloud_run_cpu           = "2000m"
cloud_run_memory        = "2Gi"

artifact_registry_project_id = "gusuval-acme-oms-stg2"
image_repo                   = "europe-west3-docker.pkg.dev/gusuval-acme-oms-stg2/oms/oms"
image_sha                    = ""

domain = ""

deletion_protection = true # innegociable

github_repository   = "gusuval/oms-platform"
github_allowed_refs = ["refs/tags/v"]
