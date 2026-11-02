terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  # Providers fijados a versión MENOR (~> X.Y.0 solo admite parches).
  # El lock exacto (con hashes) está en .terraform.lock.hcl, que se commitea.
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.45.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.0"
    }
  }

  # Backend GCS con configuración parcial: el backend no admite variables,
  # así que bucket/prefix llegan por fichero en `terraform init`:
  #   terraform init -reconfigure -backend-config=envs/staging.gcs.tfbackend
  backend "gcs" {}
}
