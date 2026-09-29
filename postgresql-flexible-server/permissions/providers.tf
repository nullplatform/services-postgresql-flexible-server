terraform {
  required_version = ">= 1.9.0"

  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.25"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# No azurerm provider here: this module touches Azure only through the
# terraform_remote_state data source (the azurerm backend, authenticated with
# the same ARM_* environment resolve_azure_credentials exports) and PostgreSQL
# itself over TLS.
provider "postgresql" {
  host     = local.server.hostname
  port     = local.server.port
  database = local.server.database_name
  username = local.server.admin_login
  password = local.server.admin_password

  # Flexible Server enforces TLS (require_secure_transport = on).
  sslmode = "require"

  # The Azure administrator is a member of azure_pg_admin, not a superuser.
  # With superuser = false the provider grants itself the link's role for the
  # operations that need ownership (REASSIGN OWNED on drop, default
  # privileges), which is exactly what Azure allows.
  superuser       = false
  connect_timeout = 30
}
