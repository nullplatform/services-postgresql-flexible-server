{
  "name": "Connect",
  "slug": "connect",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "selectors": {
    "category": "Database",
    "imported": false,
    "provider": "Azure",
    "sub_category": "Relational Database"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [],
      "properties": {
        "access_level": {
          "type": "string",
          "title": "Access Level",
          "default": "admin",
          "enum": ["read", "read-write", "admin"],
          "description": "read grants SELECT on the public schema; read-write adds INSERT, UPDATE and DELETE; admin also grants CREATE on the database and the public schema, which an application that runs its own migrations (Flyway, Liquibase, Prisma) needs.",
          "editableOn": ["create", "update"],
          "order": 1
        },
        "username": {
          "type": "string",
          "title": "Username",
          "export": { "type": "environment_variable", "target": "DATABASE_USER", "secret": false },
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "PostgreSQL role created for this link (auto-populated, delivered as DATABASE_USER)",
          "order": 2
        },
        "password": {
          "type": "string",
          "title": "Password",
          "export": { "type": "environment_variable", "target": "DATABASE_PASSWORD", "secret": true },
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Password of the link's role (auto-populated, delivered as the secret env var DATABASE_PASSWORD)",
          "order": 3
        },
        "jdbc_url": {
          "type": "string",
          "title": "JDBC URL",
          "export": { "type": "environment_variable", "target": "DATABASE_URL", "secret": false },
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "jdbc:postgresql://<host>:<port>/<database>?sslmode=require, without credentials (auto-populated, delivered as DATABASE_URL)",
          "order": 4
        }
      }
    },
    "values": {}
  }
}
