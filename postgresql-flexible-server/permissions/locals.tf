locals {
  server = data.terraform_remote_state.deployment.outputs

  # access_level -> privileges per object type, all on the public schema.
  #
  # read        browse
  # read-write  browse and change rows, never the shape of the schema
  # admin       everything, plus CREATE on the database and the public schema
  #             so an application can run its own migrations (Flyway creates
  #             its history table and, for this service's first consumer, a
  #             schema of its own)
  access_matrix = {
    "read" = {
      database = ["CONNECT"]
      schema   = ["USAGE"]
      table    = ["SELECT"]
      sequence = ["SELECT"]
    }
    "read-write" = {
      database = ["CONNECT", "TEMPORARY"]
      schema   = ["USAGE"]
      table    = ["SELECT", "INSERT", "UPDATE", "DELETE"]
      sequence = ["SELECT", "USAGE", "UPDATE"]
    }
    "admin" = {
      database = ["CONNECT", "CREATE", "TEMPORARY"]
      schema   = ["USAGE", "CREATE"]
      table    = ["ALL"]
      sequence = ["ALL"]
    }
  }

  grants = local.access_matrix[var.access_level]

  jdbc_url = "jdbc:postgresql://${local.server.hostname}:${local.server.port}/${local.server.database_name}?sslmode=require"
}
