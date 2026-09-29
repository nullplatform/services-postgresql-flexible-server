output "hostname" {
  description = "Fully qualified server name"
  value       = azurerm_postgresql_flexible_server.server.fqdn
}

output "port" {
  description = "PostgreSQL port. Flexible Server always listens on 5432."
  value       = 5432
}

output "database_name" {
  description = "Database created on the server"
  value       = azurerm_postgresql_flexible_server_database.database.name
}

output "server_name" {
  description = "Flexible Server name"
  value       = azurerm_postgresql_flexible_server.server.name
}

output "server_id" {
  description = "ARM resource ID of the Flexible Server"
  value       = azurerm_postgresql_flexible_server.server.id
}

output "resource_group_name" {
  description = "Azure resource group holding the server"
  value       = azurerm_postgresql_flexible_server.server.resource_group_name
}

# Read by the permissions/ module through terraform_remote_state, which is
# the only consumer. write_service_outputs never patches these onto the
# service, and the workflow never prints them.
output "admin_login" {
  description = "Administrator login, used by the permissions module to create per-link roles"
  value       = azurerm_postgresql_flexible_server.server.administrator_login
}

output "admin_password" {
  description = "Administrator password, used by the permissions module to create per-link roles"
  value       = random_password.admin.result
  sensitive   = true
}
