# =============================================================================
# Per-link PostgreSQL role and grants
# =============================================================================
#
# One role per link, with a generated password and grants derived from the
# link's access_level. The server coordinates and the administrator
# credentials come from the deployment module's state, never from variables.

data "terraform_remote_state" "deployment" {
  backend = "azurerm"

  config = {
    resource_group_name  = var.tfstate_resource_group_name
    storage_account_name = var.tfstate_storage_account_name
    container_name       = var.tfstate_container_name
    key                  = var.deployment_state_key
    use_azuread_auth     = true
  }
}

# Alphanumeric only: the password travels as an environment variable and may
# end up inside a connection URL assembled by the application, where URL
# reserved characters would need escaping.
resource "random_password" "link" {
  length  = 32
  special = false
}

resource "postgresql_role" "link" {
  name     = var.username
  login    = true
  password = random_password.link.result

  # Ownership of anything the role created (an admin link that ran
  # migrations) is handed to the administrator on unlink, so the role can be
  # dropped without taking the application's tables with it.
  skip_reassign_owned = false
  skip_drop_role      = false
}

resource "postgresql_grant" "database" {
  database    = local.server.database_name
  role        = postgresql_role.link.name
  object_type = "database"
  privileges  = local.grants.database
}

resource "postgresql_grant" "schema" {
  database    = local.server.database_name
  role        = postgresql_role.link.name
  schema      = "public"
  object_type = "schema"
  privileges  = local.grants.schema
}

# Every table that exists at apply time. Tables created later by the
# administrator are covered by the default privileges below; tables created
# later by another link's admin role are that role's to share.
resource "postgresql_grant" "tables" {
  database    = local.server.database_name
  role        = postgresql_role.link.name
  schema      = "public"
  object_type = "table"
  objects     = []
  privileges  = local.grants.table
}

resource "postgresql_grant" "sequences" {
  database    = local.server.database_name
  role        = postgresql_role.link.name
  schema      = "public"
  object_type = "sequence"
  objects     = []
  privileges  = local.grants.sequence
}

resource "postgresql_default_privileges" "tables" {
  database    = local.server.database_name
  role        = postgresql_role.link.name
  schema      = "public"
  owner       = local.server.admin_login
  object_type = "table"
  privileges  = local.grants.table
}

resource "postgresql_default_privileges" "sequences" {
  database    = local.server.database_name
  role        = postgresql_role.link.name
  schema      = "public"
  owner       = local.server.admin_login
  object_type = "sequence"
  privileges  = local.grants.sequence
}
