variable "service_id" {
  type        = string
  description = "Nullplatform service instance ID, tagged onto every resource"

  validation {
    condition     = length(var.service_id) > 0
    error_message = "service_id must not be empty. build_context rejects an empty or null .service.id, and this mirrors that rule so a hand-run tofu plan catches it too."
  }
}

variable "server_name" {
  type        = string
  description = "Flexible Server name, precomputed by scripts/azure/server_name"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$", var.server_name)) && length(var.server_name) >= 3
    error_message = "server_name must be 3-63 lowercase letters, digits and hyphens, and cannot start or end with a hyphen."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Azure resource group that will hold the server"

  validation {
    condition     = length(var.resource_group_name) > 0
    error_message = "resource_group_name must not be empty. Set it in values.yaml or expose it through the cloud-providers provider."
  }
}

variable "location" {
  type        = string
  default     = ""
  description = <<-EOT
    Azure region for the server. Empty (the default) means "use the target
    resource group's own location", read through a data source.

    Optional on purpose: nullplatform has no account.location equivalent for
    Azure the way it has account.region for AWS, and the agent module injects
    RESOURCE_GROUP but no region. Deriving it from the resource group is what
    lets the common single-region install configure no location at all.
  EOT
}

variable "database_name" {
  type        = string
  description = "Database created on the server"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must be 1-63 lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "postgres_version" {
  type        = string
  default     = "16"
  description = "PostgreSQL major version"

  validation {
    condition     = contains(["16", "17"], var.postgres_version)
    error_message = "postgres_version must be 16 or 17."
  }
}

variable "sku_name" {
  type        = string
  default     = "B_Standard_B1ms"
  description = "Compute SKU, in the <tier>_<name> form azurerm expects (B_Standard_B1ms, GP_Standard_D2s_v3, ...)"

  validation {
    condition     = can(regex("^(B|GP|MO)_Standard_[A-Za-z0-9_]+$", var.sku_name))
    error_message = "sku_name must look like B_Standard_B1ms, GP_Standard_D2s_v3 or MO_Standard_E2s_v3."
  }
}

variable "storage_mb" {
  type        = number
  default     = 32768
  description = "Provisioned storage in MB. Azure only accepts specific sizes and never shrinks storage."

  validation {
    condition     = contains([32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4193280, 4194304, 8388608, 16777216, 33553408], var.storage_mb)
    error_message = "storage_mb must be one of the sizes Azure supports (32768, 65536, 131072, 262144, 524288, ...)."
  }
}

variable "backup_retention_days" {
  type        = number
  default     = 7
  description = "Days Azure keeps automated backups"

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35."
  }
}

variable "high_availability" {
  type        = bool
  default     = false
  description = "Zone-redundant standby. Silently ignored on Burstable (B_) SKUs, which Azure does not allow to run with HA."
}

variable "allowed_ips" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Public IPv4 addresses, or "start-end" ranges, allowed through the server's
    firewall. The server is created with public network access, so nothing
    reaches it unless listed here: at minimum the egress IP of the cluster
    running the nullplatform agent (the link action connects from there) and
    the linked applications.
  EOT

  validation {
    condition = alltrue([
      for ip in var.allowed_ips : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(-([0-9]{1,3}\\.){3}[0-9]{1,3})?$", ip))
    ])
    error_message = "Every allowed_ips entry must be an IPv4 address (1.2.3.4) or a range (1.2.3.4-1.2.3.9)."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags propagated from the nullplatform notification context"
}
