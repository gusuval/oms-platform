#!/usr/bin/env bash
# ── bootstrap-gcp.sh ──────────────────────────────────────────────
# Prepara los proyectos GCP del OMS antes del primer `terraform apply`:
#   1. Crea los proyectos (si no existen)
#   2. Los vincula a la cuenta de facturación
#   3. Habilita las APIs mínimas (el resto las habilita Terraform)
#   4. Crea el bucket de estado de Terraform (versionado, europe-west3)
#
# Idempotente: se puede ejecutar varias veces.
#
# Uso:
#   BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX ./scripts/bootstrap-gcp.sh            # staging + production
#   BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX ./scripts/bootstrap-gcp.sh staging    # solo staging
#
# Lista tus cuentas de facturación con: gcloud billing accounts list

set -euo pipefail

REGION="europe-west3"
declare -A PROJECTS=(
  [staging]="gusuval-acme-oms-stg2"
  [production]="gusuval-acme-oms-prod"
)

: "${BILLING_ACCOUNT:?Define BILLING_ACCOUNT (gcloud billing accounts list)}"
ENVS=("${@:-staging production}")
read -r -a ENVS <<<"${ENVS[*]}"

ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
[[ -n "$ACCOUNT" ]] || { echo "No hay sesión: ejecuta 'gcloud auth login'"; exit 1; }
echo "Cuenta activa: $ACCOUNT"

for ENV in "${ENVS[@]}"; do
  P="${PROJECTS[$ENV]:?Entorno desconocido: $ENV (staging|production)}"
  echo "══ $ENV → $P"

  if gcloud projects describe "$P" >/dev/null 2>&1; then
    echo "  ✓ proyecto ya existe"
  else
    gcloud projects create "$P" --name="AcmeOMS ${ENV}" --labels="project=oms,env=${ENV}"
  fi

  if [[ "$(gcloud billing projects describe "$P" --format='value(billingEnabled)')" == "True" ]]; then
    echo "  ✓ facturación ya vinculada"
  else
    gcloud billing projects link "$P" --billing-account="$BILLING_ACCOUNT"
  fi

  gcloud services enable --project="$P" \
    serviceusage.googleapis.com cloudresourcemanager.googleapis.com \
    storage.googleapis.com cloudbilling.googleapis.com
  echo "  ✓ APIs mínimas habilitadas"

  BUCKET="gs://${P}-tfstate"
  if gcloud storage buckets describe "$BUCKET" >/dev/null 2>&1; then
    echo "  ✓ bucket de estado ya existe"
  else
    gcloud storage buckets create "$BUCKET" --project="$P" \
      --location="$REGION" --uniform-bucket-level-access --public-access-prevention
  fi
  gcloud storage buckets update "$BUCKET" --versioning >/dev/null
  echo "  ✓ $BUCKET versionado"
done

cat <<EOF

Siguiente paso:
  gcloud auth application-default login   # credenciales para Terraform
  cd terraform
  terraform init -reconfigure -backend-config=envs/staging.gcs.tfbackend
  terraform plan -var-file=envs/staging.tfvars -out=staging.tfplan
EOF
