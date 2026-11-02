# ── Entorno: PRODUCTION ─────────────────────────────────────────────
# Tier mayor, autoscaling con piso mínimo > 0 (latencia consistente),
# deletion_protection OBLIGATORIO.
#
# ⚠ La ÚNICA diferencia legítima respecto a staging.tfvars debería ser:
#    - project_id (otro proyecto)
#    - db_tier (más capacidad)
#    - cloud_run_min/max_instances (más réplicas)
#    - image_sha (cuando promocionas, este valor cambia)
#
# Si te encuentras cambiando algo más, replantéatelo.

project_id = "uval-gustavo-acme-oms-production"   # ⚠ TODO(alumno): proyecto distinto
region     = "europe-west3"               # REG-GDPR-001
env        = "production"

vpc_cidr   = "10.20.0.0/16"

db_tier    = "db-custom-4-15360"          # 4 vCPU, 15 GB RAM

cloud_run_min_instances = 2               # nunca a cero: latencia consistente
cloud_run_max_instances = 25              # NFR-SCAL-001: pico 5× del normal

image_repo = "europe-west3-docker.pkg.dev/gusuval-project/oms"
image_sha  = "sha256:GUSUVAL_GIT_SHA"

deletion_protection = true                # innegociable

github_repository = "gusuval/oms-platform"
