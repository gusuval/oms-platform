# OMS Platform — Trabajo final Bloque 4

Infraestructura de **AcmeOMS** en Google Cloud (`europe-west3`), provisionada con
**Terraform** y operada con **Ansible**, en dos entornos —staging y producción—
que ejecutan **la misma imagen (mismo digest)**.
El enunciado completo está en [`../Trabajo - enunciado.md`](../Trabajo%20-%20enunciado.md).

```
Usuarios ─HTTPS→ Cloud LB (Cloud Armor WAF + Cloud CDN, cert gestionado, HTTP→HTTPS)
                   └─ serverless NEG → Cloud Run "oms-<env>" (ingress solo LB, autoescalado)
                                         ├─ Cloud SQL Postgres 16 REGIONAL (socket, IP privada, PITR 14 d)
                                         └─ Memorystore Redis 7.2 STANDARD_HA (Direct VPC egress, TLS + AUTH)
Secretos: Secret Manager (réplica solo en europe-west3) · Audit logs → bucket con retención 3 años
CI/CD: GitHub Actions → Workload Identity Federation (sin claves)
```

## Pre-requisitos

| Herramienta | Versión mínima | Notas |
|---|---|---|
| `gcloud` | 470 | `gcloud auth login` + `gcloud auth application-default login` |
| `terraform` | 1.7 | Probado con 1.9.8 |
| `ansible-core` | 2.16 | + `ansible-galaxy collection install -r ansible/requirements.yml` |
| `docker` | 24+ | Para construir la imagen del OMS localmente |
| Python | 3.10+ | El plugin GCP de Ansible lo necesita |

## Estructura

```
oms-platform/
├── app/                      ← stub Node con /healthz (solo para validar la plataforma)
├── docker/Dockerfile         ← multi-stage, no-root, HEALTHCHECK, labels OCI
├── terraform/
│   ├── versions.tf           ← providers fijados a versión menor + backend GCS parcial
│   ├── .terraform.lock.hcl   ← lock exacto de providers (se commitea)
│   ├── main.tf · variables.tf · outputs.tf
│   ├── envs/<env>.tfvars     ← valores por entorno
│   ├── envs/<env>.gcs.tfbackend
│   └── modules/
│       ├── network/          ← VPC, 2 subredes, PSA, Cloud NAT, firewall
│       ├── database/         ← Cloud SQL + Memorystore + secretos
│       ├── compute/          ← Artifact Registry, Cloud Run, LB + CDN + WAF
│       ├── iam/              ← SAs, bindings por secreto, WIF
│       └── audit/            ← sink de audit logs a bucket con retención (REG-GDPR-003)
├── ansible/
│   ├── group_vars/{all,staging,production}.yml
│   ├── playbooks/{deploy,rollback}.yml
│   └── roles/oms_cloud_run/  ← deploy idempotente + canary por escalones
└── ../.github/workflows/ci-cd.yml   ← GitHub solo lee workflows en la raíz del repo
```

## Cómo arrancar

> Proyectos usados: `gusuval-acme-oms-staging` y `gusuval-acme-oms-prod`
> (los IDs de proyecto de GCP admiten como máximo 30 caracteres). Si los tuyos
> son otros, cámbialos en `terraform/envs/*`, `ansible/group_vars/*` y en
> `IMAGE` de `.github/workflows/ci-cd.yml`.

1. **Proyectos y APIs mínimas** (el resto las habilita Terraform con `google_project_service`):
   ```bash
   for P in gusuval-acme-oms-staging gusuval-acme-oms-prod; do
     gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com --project=$P
   done
   ```

2. **Bucket de estado por entorno** (versionado):
   ```bash
   for P in gusuval-acme-oms-staging gusuval-acme-oms-prod; do
     gcloud storage buckets create gs://$P-tfstate --project=$P \
       --location=europe-west3 --uniform-bucket-level-access
     gcloud storage buckets update gs://$P-tfstate --versioning
   done
   ```

3. **Staging primero** (aloja el Artifact Registry compartido):
   ```bash
   cd terraform
   terraform init -reconfigure -backend-config=envs/staging.gcs.tfbackend
   terraform plan  -var-file=envs/staging.tfvars -out=staging.tfplan
   terraform apply staging.tfplan
   terraform plan  -var-file=envs/staging.tfvars   # → "No changes"
   ```
   El primer apply arranca Cloud Run con una imagen *bootstrap* pública
   (`image_sha = ""`); a partir de ahí la imagen la gestiona Ansible.
   El certificado gestionado (`<IP>.nip.io` si no defines `domain`) tarda
   hasta ~60 min en quedar `ACTIVE`.

4. **Producción** (mismo código, otro backend y otros tfvars):
   ```bash
   terraform init -reconfigure -backend-config=envs/production.gcs.tfbackend
   terraform plan  -var-file=envs/production.tfvars -out=production.tfplan
   terraform apply production.tfplan
   ```
   Quien aplique necesita permisos IAM también en el proyecto de staging: se
   concede `artifactregistry.reader` al service agent de Cloud Run de producción.

5. **GitHub Actions (WIF)** — en *Settings → Secrets and variables → Actions → Variables*:

   | Variable | Valor |
   |---|---|
   | `WIF_PROVIDER_STAGING` / `WIF_PROVIDER_PRODUCTION` | `terraform output -raw workload_identity_provider` |
   | `CICD_SA_STAGING` / `CICD_SA_PRODUCTION` | `terraform output -raw cicd_service_account` |

   Crea los *environments* `staging` y `production` (en `production`, con *Required reviewers*).
   `SLACK_WEBHOOK_URL` (opcional) va como **secret**.

6. **Desplegar con Ansible** (lo hace el pipeline; a mano sería):
   ```bash
   cd ansible
   ansible-galaxy collection install -r requirements.yml
   ansible-playbook playbooks/deploy.yml -e env=staging    -e image_sha=sha256:<digest>
   ansible-playbook playbooks/deploy.yml -e env=staging    -e image_sha=sha256:<digest>  # changed=0
   ansible-playbook playbooks/deploy.yml -e env=production -e image_sha=sha256:<digest>  # mismo digest
   ansible-playbook playbooks/rollback.yml -e env=production
   ```

7. **Release**: `git tag v1.0.0 && git push github v1.0.0` → build, firma, staging, aprobación, producción.

## Pipeline

| Evento | Jobs |
|---|---|
| Pull request | `validate` (matriz staging/production: fmt, validate, syntax-check) + `test` (gitleaks, hadolint, tests) |
| Push a `main` | + `build` (push por digest + firma cosign keyless) + `deploy-staging` (verifica firma, despliega, comprueba `changed=0`) |
| Tag `v*` | + `deploy-production` con el **mismo digest** (requiere aprobación) |

La trust policy de WIF exige `assertion.repository == "gusuval/oms-platform"` y
restringe el ref: staging acepta `main` y tags `v*`; producción **solo** tags `v*`.

## Cumplimiento de la spec

| Restricción | Cómo se cumple |
|---|---|
| REG-GDPR-001 | Validación `europe-*` en `region`; secretos, backups y bucket de auditoría en `europe-west3` |
| REG-GDPR-003 | Sink de Cloud Audit Logs (+ Data Access de Cloud SQL, Secret Manager y Storage) a bucket con retention policy de 3 años; `lock_audit_retention = true` la bloquea (irreversible) |
| REG-PCI-001 | Stripe fuera de scope: ningún recurso almacena datos de tarjeta |
| NFR-AVAIL-001 | Cloud SQL `REGIONAL`, Redis `STANDARD_HA`, Cloud Run regional |
| NFR-SEC-001 | AES-256 en reposo (clave gestionada por Google); Cloud SQL `ENCRYPTED_ONLY`, Redis con TLS |
| NFR-SEC-002 | `ssl_policy` `RESTRICTED`: TLS 1.2 como mínimo aceptable, TLS 1.3 negociado por los clientes modernos; HTTP→HTTPS 301 |
| NFR-SCAL-001 | `max_instance_count` 25 en prod (5× el pico) |
| NFR-PERF-001 | Memorystore delante del catálogo (`REDIS_HOST/PORT/AUTH` inyectados) |
| OPS-005 | PITR 14 días + 14 backups (runbook abajo) |
| OPS-007 | `CACHE_FAIL_OPEN=true`: la app debe tratar Redis como opcional y leer de la BD si falla |
| Cero credenciales | WIF en CI; passwords en Secret Manager; gitleaks en el pipeline |
| Mismo `image_sha` | Un único registry; producción despliega el digest producido en el job `build` |
| Idempotencia | `terraform plan` limpio (`ignore_changes` de lo que gestiona Ansible); playbooks `changed=0` |
| Protección de la BD | `deletion_protection = true` (validado) + `prevent_destroy` + `POSTGRES_16` pinneado |

## Runbook OPS-005 — ejercicio mensual de restauración (staging)

```bash
# Restaurar PITR a una instancia NUEVA (nunca sobre la original)
gcloud sql instances clone oms-staging-postgres oms-staging-restore-$(date +%Y%m) \
  --project=gusuval-acme-oms-staging \
  --point-in-time="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"

# Verificar datos y medir el tiempo (objetivo RTO ≤ 4 h, RPO ≤ 1 h)
gcloud sql connect oms-staging-restore-$(date +%Y%m) --user=oms_app --database=oms \
  --project=gusuval-acme-oms-staging

# Limpiar
gcloud sql instances delete oms-staging-restore-$(date +%Y%m) --project=gusuval-acme-oms-staging
```

## Decisiones

### Trade-offs principales

1. **Cloud Run en lugar de GKE Autopilot.** El OMS es un monolito stateless con
   un solo contenedor: Cloud Run da autoescalado (NFR-SCAL-001), revisiones
   inmutables y reparto de tráfico (que es justo lo que necesitan el canary y
   el rollback), y se paga por uso. Con dos SREs de guardia (OPS-007), no
   gestionar nodos, upgrades ni ingress pesa más que la flexibilidad de GKE.
   Lo que se pierde: sidecars complejos y control fino de red. Si aparecen
   workers de larga duración, se reevalúa.

2. **Cloud SQL Enterprise Plus + `REGIONAL`, aunque es bastante más caro.**
   NFR-AVAIL-001 exige failover automático entre zonas (`REGIONAL` duplica el
   coste de cómputo) y OPS-005 pide 14 días de PITR. En la edición Enterprise
   el máximo de `transaction_log_retention_days` es 7, así que no se puede
   cumplir sin Enterprise Plus, que además obliga a usar tiers
   `db-perf-optimized-N-*`. También se aplica en staging, porque el ejercicio
   mensual de restauración se hace allí y debe ser representativo.

3. **Terraform crea y Ansible despliega, con un único registry en staging.**
   Terraform es dueño del servicio (secretos, VPC, probes, IAM) e ignora la
   imagen, las revisiones y el tráfico (`ignore_changes`). Ansible es dueño de
   qué digest corre y de cómo llega el tráfico (canary 10→50→100 en
   producción). Sin este reparto, cada `terraform apply` revertiría el último
   deploy y el plan nunca saldría limpio. El registry vive en el proyecto de
   staging y producción tiene permiso de lectura: se construye una vez y se
   promociona el mismo digest. La alternativa más limpia sería un tercer
   proyecto "shared"; se descartó para no añadir otro estado de Terraform.

   *Nota:* la colección `google.cloud` no incluye módulos `gcp_cloudrun_*`, así que
   el role usa `gcloud` mediante `command` (nunca `shell`), con salida JSON y
   `changed_when` explícitos. La idempotencia se ha probado: segunda ejecución
   `changed=0`, el canary interrumpido se reanuda y el rollback repetido no
   vuelve a cambiar nada.

### Cambios hechos al borrador antes de aprobarlo

1. **WIF aceptaba la audiencia de AWS.** `allowed_audiences = ["sts.amazonaws.com"]`
   venía de un ejemplo de OIDC con AWS. Se ha eliminado, de modo que GCP solo
   acepta su propia audiencia (el nombre del provider). Además, la condición
   restringe el ref por entorno.
2. **PITR de 7 días y password en texto plano en la BD.** Se ha subido
   `transaction_log_retention_days` a 14 (con Enterprise Plus) y el placeholder
   `password = "TODO…"` se ha sustituido por `random_password` y una versión en
   Secret Manager. El `secretAccessor` de nivel proyecto pasa a concederse
   secreto a secreto. El AUTH de Redis también va a Secret Manager.
3. **Errores que solo salían al validar.** `cdn_policy` no pasaba `terraform
   validate` sin `cache_key_policy`. `stdout_callback = yaml` ya no existe en
   `community.general` ≥ 12. Si Ansible pasaba `--cpu/--memory` distintos de los
   de Terraform, el plan se ensuciaba en cada deploy (ahora ambos usan los
   mismos valores). Y la directiva `# syntax=` del Dockerfile no estaba en la
   primera línea, por lo que Docker la ignoraba.

## Verificación final

```bash
cd terraform
terraform fmt -check -recursive && terraform validate
terraform plan -var-file=envs/staging.tfvars              # No changes
cd ../ansible
ansible-playbook playbooks/deploy.yml -e env=staging -e image_sha=sha256:<digest> --check  # changed=0
diff group_vars/staging.yml group_vars/production.yml     # solo identidad/capacidad
cd ..
gitleaks detect --source . --no-banner
grep -rn "TODO" --exclude=README.md .                     # vacío
```

## Bonus pendientes (no implementados)

Multi-region DR (`europe-central2`), bastion con Datadog, CMEK propia, políticas
finas de CDN con signed URLs y documentación de expand-and-contract.
