variable "link_id" {
  type        = string
  description = "Nullplatform link ID, used for traceability"

  validation {
    condition     = length(var.link_id) > 0
    error_message = "link_id must not be empty. build_permissions_context refuses to run without it, and this mirrors that rule."
  }
}

variable "username" {
  type        = string
  description = "PostgreSQL role to create for this link, precomputed by build_context and stable across updates"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{2,62}$", var.username))
    error_message = "username must be 3-63 lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "access_level" {
  type        = string
  default     = "admin"
  description = "Grants given to the role: read, read-write or admin"

  validation {
    condition     = contains(["read", "read-write", "admin"], var.access_level)
    error_message = "access_level must be read, read-write or admin."
  }
}

# --- Where the deployment module left its state ------------------------------
# The server's hostname, database and administrator credentials are read from
# there rather than passed in: the password never crosses the workflow
# engine's environment channel, and the hostname cannot drift from what was
# actually created.

variable "tfstate_resource_group_name" {
  type        = string
  description = "Resource group of the storage account holding the tfstate"

  validation {
    condition     = length(var.tfstate_resource_group_name) > 0
    error_message = "tfstate_resource_group_name must not be empty."
  }
}

variable "tfstate_storage_account_name" {
  type        = string
  description = "Storage account holding the tfstate"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.tfstate_storage_account_name))
    error_message = "tfstate_storage_account_name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "tfstate_container_name" {
  type        = string
  description = "Blob container holding the tfstate"

  validation {
    condition     = length(var.tfstate_container_name) > 0
    error_message = "tfstate_container_name must not be empty."
  }
}

variable "deployment_state_key" {
  type        = string
  description = "Blob key of the deployment module's state for this service instance"

  validation {
    condition     = endswith(var.deployment_state_key, "/deployment.tfstate")
    error_message = "deployment_state_key must point at a deployment.tfstate blob."
  }
}
