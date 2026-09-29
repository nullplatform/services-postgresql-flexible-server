################################################################################
# Install — registers the postgresql-flexible-server service specification, its
# connect link specification, and the agent association (notification channel)
# on a nullplatform account.
#
# Azure has no requirements/ module: the AssumeRole permissions model is
# AWS-only, so there is no IAM role to provision here. Grant the agent's Azure
# identity (or the service principal published through the cloud-providers
# provider) Contributor on the target resource group instead — see "Azure
# permissions" in the service README.
#
# Two deployment models, selected by whether var.package_version is set — see
# the block comment above the package variables in variables.tf.
################################################################################

locals {
  service_path      = "postgresql-flexible-server"
  available_links   = ["connect"]
  available_actions = []

  packaged = var.package_version != null

  # Bill of materials for the package revision. service_definition adds the
  # spec/link/action components itself; the caller supplies the artifacts.
  package_config = local.packaged ? {
    slug       = var.package_slug
    name       = var.service_name
    version    = var.package_version
    default    = var.package_default
    visible_to = var.package_visible_to
    artifacts = [{
      name   = "impl"
      type   = "oci_image"
      lookup = false
      meta = {
        registry   = var.image_registry
        repository = var.image_repository
        digest     = var.image_digest
      }
    }]
  } : null

  # Unreferenced by the module when worker_orchestrator = true (it builds no
  # clone path at all), but the variable is not nullable there: a real null
  # would break the cmdline interpolation on the git-clone branch rather than
  # fall back to the module default. The precondition below is what actually
  # requires an explicit value in the git-clone model.
  base_clone_path = coalesce(var.base_clone_path, "/home/agent/.np")
}

# Guard rails that a single variable's own validation block cannot express,
# because each depends on the value of another variable.
resource "terraform_data" "install_preconditions" {
  input = local.packaged ? "packaged" : "git-clone"

  lifecycle {
    precondition {
      condition     = local.packaged || var.base_clone_path != null
      error_message = "base_clone_path is required in the git-clone deployment model. Set it to the agent image's actual home (see the variable's description), or set package_version to use the packaged model, where it is not read at all."
    }
    precondition {
      condition     = !local.packaged || (var.image_registry != "" && var.image_digest != "")
      error_message = "image_registry and image_digest are required when package_version is set: a package revision with no pinned image would register a service the agent cannot run."
    }
    precondition {
      condition     = !local.packaged || var.worker_entrypoint != ""
      error_message = "worker_entrypoint must name the entrypoint path inside the worker image."
    }
  }
}

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=${var.tofu_modules_ref}"

  nrn               = var.nrn
  service_path      = local.service_path
  service_name      = var.service_name
  available_links   = local.available_links
  available_actions = local.available_actions

  # Local mode reads the specs straight off the filesystem, so the service can
  # be iterated on without pushing. Remote mode reads them over HTTP from git.
  # This is unaffected by the deployment model: the specs come from git either
  # way, and the package pins the result rather than replacing the fetch.
  git_provider     = var.git_provider
  local_specs_path = var.local_specs_path

  repository_org    = var.repository_org
  repository_name   = var.repository_name
  repository_branch = var.repository_branch
  # Selects the git ref namespace repository_branch is resolved in: "tags"
  # for a pinned release tag, "heads" for a branch, or "" for a raw commit
  # SHA. Set explicitly (default "tags" in variables.tf) rather than relying
  # on the module's own default, because that default is not stable across
  # tofu-modules refs — see the repository_ref_type variable description.
  repository_ref_type = var.repository_ref_type
  repository_token    = var.repository_token

  # Null in the git-clone model — the module then behaves exactly as before.
  package = local.package_config
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=${var.tofu_modules_ref}"

  nrn                        = var.nrn
  service_path               = local.service_path
  service_specification_slug = module.service_definition.service_specification_slug
  api_key                    = var.np_api_key
  tags_selectors             = var.tags_selectors

  # --- git-clone model ------------------------------------------------------
  # Both are ignored by the module when worker_orchestrator = true.
  repository_service_spec_repo = "${var.repository_org}/${var.repository_name}"
  base_clone_path              = local.base_clone_path

  # --- packaged model -------------------------------------------------------
  # worker_orchestrator flips the channel from a git-clone "exec" command to a
  # "package-exec" one, which routes to an agent that spawns the package's
  # worker image. package_slug is both the NP_PLUGIN and the package the agent
  # resolves; defaulting it to the service spec's own slug is what
  # `np package publish` would also produce.
  worker_orchestrator = local.packaged
  package_slug        = local.packaged ? coalesce(var.package_slug, module.service_definition.service_specification_slug) : ""
  entrypoint          = local.packaged ? var.worker_entrypoint : ""

  depends_on = [terraform_data.install_preconditions]
}
