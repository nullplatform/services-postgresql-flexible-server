# Azure PostgreSQL Flexible Server Service

Nullplatform **dependency service** that provisions and manages an Azure
Database for PostgreSQL Flexible Server. Each service instance is one server
with one database; each application link creates a dedicated PostgreSQL role
with grants for its access level, so apps authenticate with their own
credentials and never see the administrator's.

The service lives under [`postgresql-flexible-server/`](./postgresql-flexible-server)
and follows the layout of [services-blob-storage](https://github.com/nullplatform/services-blob-storage),
the reference for Azure services: the credential and placement resolution,
the OpenTofu execution and the state layout are the same code.

## What It Does

- Provisions a Flexible Server (version, SKU, storage, backup retention,
  optional zone-redundant HA) and a database via OpenTofu, with TLS enforced
  (`require_secure_transport = on`)
- Opens the server's firewall only to the addresses you list (the cluster's
  egress IP, at minimum)
- Creates a PostgreSQL role per link, with a generated password and grants
  derived from the link's access level; drops it on unlink, keeping the data
- Exposes `{LINK}_HOSTNAME` / `{LINK}_PORT` / `{LINK}_DATABASE_NAME` from the
  service, and **`DATABASE_URL` / `DATABASE_USER` / `DATABASE_PASSWORD`** from
  the link, the names a Spring Boot `container` profile reads without mapping
- Stores OpenTofu state in a shared container under a per-service key
  (`postgresql-flexible-server/<service_id>/`), authenticating with Azure AD
  (`use_azuread_auth=true`) rather than the account's shared key
- Ships as an OCI worker image: the channel routes `package-exec` to a worker
  built from this repository's [`Dockerfile`](./Dockerfile), with OpenTofu
  baked in

## Repository Layout

```
.
├── postgresql-flexible-server/
│   ├── specs/
│   │   ├── service-spec.json.tpl   # Service schema (attributes the user sees)
│   │   ├── links/connect.json.tpl  # Link schema (access level, credentials)
│   │   └── install/azure/          # OpenTofu: standalone registration module
│   ├── deployment/                 # OpenTofu module: server, database, firewall
│   ├── permissions/                # OpenTofu module: role + grants (per link)
│   ├── workflows/azure/            # Workflow YAMLs (create/update/delete/link/link-update/unlink/read)
│   ├── scripts/azure/              # credential + placement resolution, tofu execution, output writing
│   ├── entrypoint/                 # entrypoint/service/link (agent entrypoint)
│   ├── examples/                   # fixtures and the offline test harness
│   └── values.yaml                 # Static config, optional — all keys may stay empty
├── Dockerfile                      # worker image: worker-bridge + OpenTofu + this service
├── mise.toml                       # run it on your machine as a package (np package run)
└── README.md
```

## Service Configuration Parameters

Exposed in the nullplatform UI when creating/updating the service:

| Parameter | Type | Default | Allowed Values | Editable After Create |
|---|---|---|---|---|
| `database_name` | string | — (required) | `^[a-z][a-z0-9_]{0,62}$` | No |
| `postgres_version` | string | `16` | `16`, `17` | No. 17 on a Burstable SKU fails in some regions (eastus2); use a GP SKU with 17 |
| `sku_name` | string | `B_Standard_B1ms` | `B_Standard_B1ms`, `B_Standard_B2s`, `B_Standard_B2ms`, `GP_Standard_D2s_v3`, `GP_Standard_D4s_v3` | Yes |
| `storage_mb` | number | `32768` | 32768, 65536, 131072, 262144, 524288 | Yes (grow only) |
| `backup_retention_days` | number | `7` | 7–35 | Yes |
| `high_availability` | bool | `false` | | Yes (ignored on `B_` SKUs) |

TLS enforcement, the administrator login (`npadmin`) and public network
access are fixed in the module and deliberately not exposed.

**Server naming**: `<sanitized-service-name>-<first 8 chars of service ID>`,
capped at 63 characters. Computed once on first create, then persisted and
read back on every later action — recomputing it after a rename would force
`replace` on the server and destroy every database in it.

## Link Parameters (`connect`)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `access_level` | enum | `admin` | `read`, `read-write`, `admin` |

`access_level` maps onto grants, all on the `public` schema of the service's
database:

| Access level | Database | Schema `public` | Tables | Sequences |
|---|---|---|---|---|
| `read` | CONNECT | USAGE | SELECT | SELECT |
| `read-write` | CONNECT, TEMPORARY | USAGE | SELECT, INSERT, UPDATE, DELETE | SELECT, USAGE, UPDATE |
| `admin` | CONNECT, CREATE, TEMPORARY | USAGE, CREATE | ALL | ALL |

`admin` is the default because the first consumers run their own migrations
(Flyway, Liquibase, Prisma): they need CREATE on the database to create their
schema and CREATE on `public` for the migration history table. Tables an
`admin` role creates are owned by that role; grants on them for a later
`read` link are the owner's to give (see "Grants cover the public schema").

## Service Attributes (post-create, exported as env vars)

| Attribute | Description |
|---|---|
| `hostname` | `<server>.postgres.database.azure.com` |
| `port` | `5432` |
| `database_name` | The database |

Names are `{LINK_SLUG_UPPER}_{ATTRIBUTE_UPPER}` with hyphens removed from the
slug: a link slugged `db-main` yields `DBMAIN_HOSTNAME`, `DBMAIN_PORT` and
`DBMAIN_DATABASE_NAME`.

`server_name`, `server_id` and `resource_group_name` are also stored, but not
exported — `server_name` is what keeps the name stable across renames.

## Link Attributes (per link, exported as env vars)

| Attribute | Env var | Type | Description |
|---|---|---|---|
| `username` | `DATABASE_USER` | plain | The link's role, `u_<app>_<link id prefix>` |
| `password` | `DATABASE_PASSWORD` | secret | Its password, 32 alphanumerics |
| `jdbc_url` | `DATABASE_URL` | plain | `jdbc:postgresql://<host>:5432/<db>?sslmode=require`, no credentials |

The link uses `export.target` to fix these names instead of the
`{LINK}_...` convention, so an application reads them with no mapping. The
consequence is that **one scope can consume one link of this service**: two
links to two servers would both try to export `DATABASE_URL`.

## Workflows

| Workflow | Trigger | What It Does |
|---|---|---|
| `create` | Service created | Creates the server, the database and the firewall rules |
| `update` | Service updated | Re-applies SKU, storage, backup retention, HA and firewall |
| `delete` | Service deleted | **Destroys the server**, its database and all data |
| `link` | Application linked | Creates the role with its grants |
| `link-update` | Link updated | Reapplies the grants after an `access_level` change; password unchanged |
| `unlink` | Application unlinked | **Drops the role**; its objects are reassigned to the administrator, data is kept |
| `read` | Read action | Reports current attributes; touches nothing in Azure |

## Requirements

### nullplatform prerequisites

- An agent with worker orchestration enabled, and this service's package slug
  listed in the agent module's `worker_orchestrated_packages`
- The agent's worker needs the Azure environment (`ARM_*` or `AZURE_*`,
  `RESOURCE_GROUP`, `AZURE_TFSTATE_*`); see "How to register" below
- A Storage Account with an **existing** blob container for OpenTofu state.
  This service never creates one: it writes a per-service key into a container
  that already exists
- The egress IP of the cluster running the agent, listed in `allowed_ips`:
  the link action connects to the server from the worker pod

### Azure permissions

The identity running this service — the agent's service principal or managed
identity — needs:

| On | Role | For |
|---|---|---|
| The target resource group | `Contributor` | creating Flexible Servers, databases and firewall rules |
| The tfstate container | `Storage Blob Data Contributor` | reading and writing state |

`Storage Blob Data Contributor` does not grant ARM `listKeys`, which is exactly
why the backend is initialized with `use_azuread_auth=true`.

### Runtime dependencies

- **OpenTofu** — baked into the worker image at the version pinned by the
  Dockerfile's `TOFU_VERSION`. `do_tofu` keeps a download fallback for agents
  without it, but the packaged deployment never uses it.
- `bash`, `jq`, `np` and `curl` ship in the `worker-bridge` base image.
- **No `azure-cli`, no `psql`**: roles and grants are managed by the
  `cyrilgdn/postgresql` Terraform provider over TLS.

## Configuration

Three tiers, each field resolved independently, highest first:

1. `postgresql-flexible-server/values.yaml` (committed; ships empty)
2. The `services` block of the account's cloud-providers (Azure) provider config
3. The agent's environment

| Setting | values.yaml | Provider (`.services.`) | Environment |
|---|---|---|---|
| Resource group | `resource_group_name` | `resource_group_name` | `SERVICES_RESOURCE_GROUP`, then `RESOURCE_GROUP` |
| Location | `location` | `location` | `SERVICES_LOCATION` (empty = the resource group's) |
| Firewall | `allowed_ips` | `postgresql.allowed_ips` (array or CSV) | `SERVICES_PG_ALLOWED_IPS` (CSV) |
| State account | `tfstate_storage_account` | `tfstate.storage_account` | `AZURE_TFSTATE_STORAGE_ACCOUNT` |
| State container | `tfstate_container` | `tfstate.container` | `AZURE_TFSTATE_CONTAINER` |
| State resource group | `tfstate_resource_group` | `tfstate.resource_group_name` | `AZURE_TFSTATE_RESOURCE_GROUP` (empty = target RG) |

Credentials follow the same tiers through the provider's `.authentication`
block and the `ARM_*` / `AZURE_*` variables; nothing anywhere means the
agent's own identity.

## How to register this service in nullplatform

Three pieces, in three layers.

**1 — The agent** must be able to run the worker and give it the Azure
environment. In the [`nullplatform/agent`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/agent)
module:

```hcl
  worker_orchestrated_packages = ["azure-postgresql-flexible-server"]

  worker = {
    patches = [{
      target = { package = "azure-postgresql-flexible-server" }
      merge = {
        spec = {
          containers = [{
            name    = "worker"
            envFrom = [{ secretRef = { name = "<agent-secret>" } }]
          }]
        }
      }
    }]
  }

  extra_envs = {
    AZURE_TFSTATE_STORAGE_ACCOUNT = "<tfstate account>"
    AZURE_TFSTATE_CONTAINER       = "<tfstate container>"
    AZURE_TFSTATE_RESOURCE_GROUP  = "<tfstate resource group>"
    SERVICES_PG_ALLOWED_IPS       = "<cluster egress ip>"
  }
```

The `envFrom` is required. The module injects the Azure environment only into
the `containers` package's worker, so any other package's worker starts with
none of it. `extra_envs` land in the agent's Helm secret, which the patch
mounts.

**2 — The service specification**, with the worker image pinned:

```hcl
module "service_definition_postgresql_flexible_server" {
  source              = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v8.0.0"
  nrn                 = var.nrn
  service_path        = "postgresql-flexible-server"
  service_name        = "Azure PostgreSQL Flexible Server"
  repository_name     = "services-postgresql-flexible-server"
  repository_branch   = "<tag>"
  repository_ref_type = "tags"
  available_links     = ["connect"]

  package = {
    version = "<semver>"
    artifacts = [{
      name   = "worker-image"
      type   = "oci_image"
      lookup = true
      meta = {
        registry   = "public.ecr.aws"
        repository = "nullplatform/agent-plugins/services/postgresql-flexible-server"
        tag        = "<tag>"
      }
    }]
  }
}
```

**3 — The channel association**, routing the action to the worker:

```hcl
module "service_agent_association_postgresql_flexible_server" {
  source                     = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v8.0.0"
  nrn                        = var.nrn
  api_key                    = var.np_api_key
  service_path               = "postgresql-flexible-server"
  service_specification_slug = module.service_definition_postgresql_flexible_server.service_specification_slug
  tags_selectors             = var.tags_selectors

  worker_orchestrator = true
  package_slug        = module.service_definition_postgresql_flexible_server.service_specification_slug
}
```

A ready-made version of pieces 2 and 3 lives in
[`postgresql-flexible-server/specs/install/azure/`](postgresql-flexible-server/specs/install/azure)
for a standalone install.

## Important considerations

### Delete destroys everything

`delete` destroys the server, which deletes the database, every role and all
their data. Azure's automated backups exist only while the server does; there
is no final snapshot. Unlink, by contrast, keeps the data: the role's objects
are reassigned to the administrator before the role is dropped.

### The server is reachable from the public internet

The server is created with `public_network_access_enabled = true` and no
firewall rule beyond the ones in `allowed_ips`; with an empty list nothing
can connect, and `create` says so loudly. TLS is mandatory. Private access
(a VNet-delegated subnet plus a private DNS zone) is not implemented: it
needs a delegated subnet the caller's network layer has to own.

### Grants cover the public schema

The role's grants apply to the `public` schema, to the tables that exist at
link time, and — through default privileges — to tables the administrator
creates later. Tables created by another link's `admin` role (an application
running its own migrations, possibly in a schema of its own) are owned by that
role; a `read` link does not see them until their owner grants access. For a
single application per database, the common case, this never comes up.

### A password is issued once

The link's password is generated on `link` and anchored in state; `link-update`
changes grants and nothing else. Rotation is deleting and recreating the link.

### The tfstate is a credential store

The deployment state holds the administrator password and every link state
holds its role's password. That is unavoidable with Terraform, but it means
**anyone with read access to the tfstate container holds every credential
this service has issued.** Treat that container with the same care as a vault.

### Creation takes minutes

Azure provisions a Flexible Server in roughly five to ten minutes. The
`create` action runs that long; a link issued before `create` completes fails
with a clear "hostname not found" error and can be retried.

## Testing

The offline suite needs no Azure session, no agent and no platform: it stubs
`np`, `az` and `tofu` on `PATH`.

```bash
bash postgresql-flexible-server/examples/run-all-tests.sh
```

A dry run parses a notification fixture, prints the derived variables and
validates the Terraform module. It needs placement from somewhere: either fill
`values.yaml` locally or export the agent's variables:

```bash
export RESOURCE_GROUP=<rg> AZURE_TFSTATE_STORAGE_ACCOUNT=<account> AZURE_TFSTATE_CONTAINER=<container>
bash postgresql-flexible-server/examples/dry-run.sh
bash postgresql-flexible-server/examples/dry-run.sh postgresql-flexible-server/examples/link.json
```

`full-test.sh` applies the modules against a real Azure subscription, outside
the platform. It creates real resources.

## Run locally as a package

`np package run` runs this service on your machine the way production does: a
local controlplane-agent that registers with the platform, spawns the worker
image built from this repo, and hands it every action routed to it. The two
tasks in `mise.toml` are the whole contract with the CLI:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `postgresql-flexible-server-worker:dev` |
| `np package run` | `mise run run` | Builds the image, then starts the local agent |

The agent is tagged `package:azure-postgresql-flexible-server` and `local:<your user>`.
It receives an action only when the service's notification channel selects
those tags, so point a channel at `local:<your user>` to route work to your
machine. **Never start a local agent with tags a production channel selects.**

## CI

| Workflow | When | What |
|---|---|---|
| specs | PR | service and link specs, plus the offline suite |
| terraform | PR | `tofu fmt`, `init` and `validate` on both modules |
| shellcheck | PR | every bash script |
| trivy | PR | IaC misconfiguration and image scan, to the Security tab |
| test-image | same-repo PR | pushes `pr-<number>` to test before merging |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` to ECR Public → nullplatform artifact → GitHub release |
| auto-merge-release | after release | merges the release PR |

## Publishing

After adding the **Public ECR** service to the application, set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN the Public ECR service returns |
| `NP_ARTIFACT_NRN` | variable | `organization=4` |

`ARTIFACT_NP_API_KEY` comes from the organization. The release checks all
three before building and fails with a clear error if one is missing.
