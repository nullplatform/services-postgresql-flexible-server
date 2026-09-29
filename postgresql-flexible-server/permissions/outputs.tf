output "username" {
  description = "PostgreSQL role created for this link"
  value       = postgresql_role.link.name
}

output "password" {
  description = "Password of the link's role"
  value       = random_password.link.result
  sensitive   = true
}

output "jdbc_url" {
  description = "JDBC URL of the database, TLS required, without credentials"
  value       = local.jdbc_url
}

# Emitted for debugging only. The service spec already exports hostname, port
# and database_name, so write_link_outputs must not patch them onto the link.
output "hostname" {
  description = "Server hostname read from the deployment state"
  value       = local.server.hostname
}

output "database_name" {
  description = "Database name read from the deployment state"
  value       = local.server.database_name
}
