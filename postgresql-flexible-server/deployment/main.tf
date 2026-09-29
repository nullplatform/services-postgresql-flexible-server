# =============================================================================
# Azure Database for PostgreSQL - Flexible Server
# =============================================================================
#
# Provisions one Flexible Server with one database per nullplatform service
# instance. Roles for applications are NOT created here: each link creates its
# own role, with grants derived from the link's access level, through the
# permissions/ module.

# Resolves var.location when it is empty. Reading the resource group also
# fails early, and with a clear Azure error, when the group does not exist.
data "azurerm_resource_group" "target" {
  name = var.resource_group_name
}

locals {
  location = var.location != "" ? var.location : data.azurerm_resource_group.target.location

  # Azure rejects HA on Burstable SKUs outright. Dropping it here, instead of
  # failing the create, keeps the attribute meaningful on a later SKU change.
  ha_enabled = var.high_availability && !startswith(var.sku_name, "B_")

  firewall_rules = {
    for entry in var.allowed_ips : entry => {
      start = split("-", entry)[0]
      end   = length(split("-", entry)) > 1 ? split("-", entry)[1] : split("-", entry)[0]
    }
  }

  tags = merge(var.tags, {
    "Name"       = var.server_name
    "managed-by" = "nullplatform"
    "service-id" = var.service_id
  })
}

# The administrator password lives in this module's state and nowhere else:
# the permissions/ module reads it back through terraform_remote_state to
# create the per-link roles. Applications never receive it.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "!#%^*-_+="
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "azurerm_postgresql_flexible_server" "server" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = local.location

  version    = var.postgres_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = false

  administrator_login    = "npadmin"
  administrator_password = random_password.admin.result

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  # Public endpoint, reachable only from the addresses in var.allowed_ips.
  # Private access (VNet-delegated subnet and private DNS zone) is a v2
  # concern: it needs a delegated subnet the caller's network layer has to own.
  public_network_access_enabled = true

  dynamic "high_availability" {
    for_each = local.ha_enabled ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  tags = local.tags

  lifecycle {
    # Azure picks the zone at creation and moves the standby on failover;
    # tracking either would propose a rebuild on every apply after one.
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }
}

# Fixed, deliberately not exposed in the service schema: every client must
# speak TLS. The linked applications get sslmode=require in their JDBC URL.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.server.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_database" "database" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.server.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allowed" {
  for_each = local.firewall_rules

  name             = "np-${replace(each.key, ".", "-")}"
  server_id        = azurerm_postgresql_flexible_server.server.id
  start_ip_address = each.value.start
  end_ip_address   = each.value.end
}
