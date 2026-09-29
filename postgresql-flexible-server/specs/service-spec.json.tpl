{
  "name": "Azure PostgreSQL Flexible Server",
  "slug": "azure-postgresql-flexible-server",
  "type": "dependency",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "available_links": ["connect"],
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
      "required": ["database_name"],
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          {
            "type": "Control",
            "label": "Database Name",
            "scope": "#/properties/database_name"
          },
          {
            "type": "Control",
            "label": "PostgreSQL Version",
            "scope": "#/properties/postgres_version",
            "options": { "format": "radio" }
          },
          {
            "type": "Control",
            "label": "Compute (SKU)",
            "scope": "#/properties/sku_name"
          },
          {
            "type": "Control",
            "label": "Storage (MB)",
            "scope": "#/properties/storage_mb"
          },
          {
            "type": "Categorization",
            "options": {
              "collapsable": { "label": "ADVANCED", "collapsed": true }
            },
            "elements": [
              {
                "type": "Category",
                "label": "Resilience",
                "elements": [
                  {
                    "type": "Control",
                    "label": "Backup Retention (days)",
                    "scope": "#/properties/backup_retention_days"
                  },
                  {
                    "type": "Control",
                    "label": "Zone-redundant High Availability",
                    "scope": "#/properties/high_availability"
                  }
                ]
              }
            ]
          },
          {
            "type": "Control",
            "label": "Hostname",
            "scope": "#/properties/hostname"
          },
          {
            "type": "Control",
            "label": "Port",
            "scope": "#/properties/port"
          }
        ]
      },
      "properties": {
        "database_name": {
          "type": "string",
          "title": "Database Name",
          "export": true,
          "description": "Database created on the server. Lowercase letters, digits and underscores, starting with a letter. Up to 63 characters.",
          "pattern": "^[a-z][a-z0-9_]{0,62}$",
          "editableOn": ["create"],
          "order": 1
        },
        "postgres_version": {
          "type": "string",
          "title": "PostgreSQL Version",
          "default": "17",
          "enum": ["16", "17"],
          "description": "Major version. Cannot be changed after creation: an in-place major upgrade is an Azure operation outside this service.",
          "editableOn": ["create"],
          "order": 2
        },
        "sku_name": {
          "type": "string",
          "title": "Compute (SKU)",
          "default": "B_Standard_B1ms",
          "enum": ["B_Standard_B1ms", "B_Standard_B2s", "B_Standard_B2ms", "GP_Standard_D2s_v3", "GP_Standard_D4s_v3"],
          "description": "Burstable (B_) tiers are the cheapest and suit development. General Purpose (GP_) tiers are for steady production load and are the only ones that support high availability.",
          "editableOn": ["create", "update"],
          "order": 3
        },
        "storage_mb": {
          "type": "number",
          "title": "Storage (MB)",
          "default": 32768,
          "enum": [32768, 65536, 131072, 262144, 524288],
          "description": "Provisioned storage. It can grow on update but never shrink: Azure does not support reducing storage.",
          "editableOn": ["create", "update"],
          "order": 4
        },
        "backup_retention_days": {
          "type": "number",
          "title": "Backup Retention (days)",
          "default": 7,
          "minimum": 7,
          "maximum": 35,
          "description": "Days Azure keeps automated backups for point-in-time restore.",
          "editableOn": ["create", "update"],
          "order": 5
        },
        "high_availability": {
          "type": "boolean",
          "title": "Zone-redundant High Availability",
          "default": false,
          "description": "Keeps a hot standby in another availability zone. Doubles the compute cost and is ignored on Burstable SKUs, which do not support it.",
          "editableOn": ["create", "update"],
          "order": 6
        },
        "hostname": {
          "type": "string",
          "title": "Hostname",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Fully qualified server name (auto-populated after creation)",
          "order": 7
        },
        "port": {
          "type": "number",
          "title": "Port",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "PostgreSQL port (auto-populated after creation)",
          "order": 8
        },
        "server_name": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal: Azure Flexible Server name. Computed once on first create and read back on every later action so a rename never forces a replacement."
        },
        "server_id": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal: ARM resource ID of the Flexible Server"
        },
        "resource_group_name": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal: Azure resource group holding the server"
        }
      }
    },
    "values": {}
  }
}
