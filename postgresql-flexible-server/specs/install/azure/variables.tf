variable "nrn" {
  description = "Namespace-level NRN where the service definition is registered, e.g. organization=<org>:account=<account>:namespace=<namespace>. The agent association MUST use this same NRN, or actions fail with \"There is not a channel for the given parameters\"."
  type        = string
}

variable "np_api_key" {
  description = "nullplatform API key the agent association uses to authenticate. Maps onto the service_definition_agent_association module's `api_key` variable."
  type        = string
  sensitive   = true
}

variable "tags_selectors" {
  description = "Agent tag selectors for the notification channel. MUST match the tags the target agent registers with (np-agent -tags), or notifications are created but never routed to any agent."
  type        = map(string)
}

variable "tofu_modules_ref" {
  description = "Ref of nullplatform/tofu-modules to source the registration modules from (e.g. a tag such as \"v7.3.0\"). No default on purpose: confirm the current ref against the repository before applying — these repos are mid-migration from release branches to tags, and a ref that worked for another service may not exist here."
  type        = string
}

variable "service_name" {
  description = "Display name of the service in the nullplatform UI."
  type        = string
  default     = "Azure PostgreSQL Flexible Server"
}

variable "git_provider" {
  description = "\"local\" reads specs from local_specs_path (recommended while iterating); \"github\" (the default) reads them over HTTP from the repository. \"gitlab\" and \"bitbucket\" are also supported by the underlying module but not exercised by this install."
  type        = string
  default     = "github"
}

variable "local_specs_path" {
  description = "Absolute path to the postgresql-flexible-server service directory (must contain specs/service-spec.json.tpl and specs/links/*.json.tpl). Required when git_provider is \"local\"."
  type        = string
  default     = null
}

variable "base_clone_path" {
  description = <<-EOT
    Where the agent looks for cloned repos, used to build the agent's exec
    cmdline. Getting this wrong is silent: the channel registers fine and the
    resulting notification fails at the agent with something like "command
    not found in any allowed paths" — nothing here catches a wrong value.

    No default on purpose: the right value tracks the deployed AGENT image
    (its container's home directory), not the tofu-modules ref this install
    happens to pin, and the two are versioned independently. The module's own
    convenience default has in fact changed across the refs read while
    building this install: "/root/.np" at tofu-modules v7.1.0 and earlier (a
    root-user agent image), "/home/agent/.np" from v7.2.0 onward (PR #554,
    merged 2026-09-03, added a non-root "agent"-user image alongside
    worker-orchestrator support) — confirmed present at v7.3.0, the tip of
    main as of 2026-09-04. Do not copy either value from this file or from
    the module's docs; confirm the actual $HOME of the agent pod/process that
    will run this service (e.g. `kubectl exec <agent-pod> -- env | grep HOME`
    for a Kubernetes agent).

    For a local (host-runtime) agent started via `np-agent -runtime host`,
    use pathexpand("~/.np") instead — see the repo README's "End-to-end
    testing" section.

    Optional ONLY in the packaged deployment model (package_version set):
    with worker_orchestrator = true the module builds no clone path at all —
    it emits a package-exec channel and the agent runs the worker image's
    baked entrypoint. In the git-clone model this is still required, and a
    precondition in main.tf enforces it.
  EOT
  type        = string
  default     = null
}

variable "repository_org" {
  description = "GitHub organization or user hosting this repository. Override only when installing from a fork."
  type        = string
  default     = "nullplatform"
}

variable "repository_name" {
  description = "Repository name hosting the postgresql-flexible-server service spec templates."
  type        = string
  default     = "services-postgresql-flexible-server"
}

variable "repository_branch" {
  description = <<-EOT
    Pinned git ref of THIS repository (services-postgresql-flexible-server) to register the
    specs from, as a short name — e.g. "v1.0.0", not "refs/tags/v1.0.0".

    No default here, as our OWN policy: pin an immutable ref rather than
    track a moving branch. This is not universally enforced by
    tofu-modules — it depends on which ref tofu_modules_ref selects. As of
    v7.3.0 (the tip of main as of 2026-09-04) the service_definition module
    does validate this: non-empty and NOT "main"/"master"/"head"/"latest"
    (case-insensitive), even when git_provider = "local" (validated but not
    fetched). That validation was added in v7.2.0 (PR #554, merged
    2026-09-03) — at v7.1.0 and earlier the module had no such validation and
    defaulted repository_branch to "main". Do not rely on the module to catch
    a moving-branch mistake if you pin tofu_modules_ref to an older ref;
    treat the "no default" here as the actual guardrail regardless of which
    ref is chosen.

    Pair with repository_ref_type to say whether this name is a tag or a
    branch.
  EOT
  type        = string
}

variable "repository_ref_type" {
  description = <<-EOT
    Git ref namespace for repository_branch on GitHub: "tags" (repository_branch
    is a tag name), "heads" (repository_branch is a branch name, still not
    main/master/head/latest), or "" to treat repository_branch as a raw
    commit SHA.

    Defaulted here to "tags" as our own policy, pairing with the pinned-ref
    policy on repository_branch above. This happens to match the
    service_definition module's own current default at v7.3.0 (the tip of
    main as of 2026-09-04) — but that default was "heads" at v7.2.0 and
    earlier (including v7.1.0) and only changed to "tags" in the same v7.2.0
    change (PR #554, merged 2026-09-03) that added the repository_branch
    validation above. Set explicitly here so this install's behavior does not
    silently change if tofu_modules_ref is pointed at an older ref.
  EOT
  type        = string
  default     = "tags"
}

variable "repository_token" {
  description = "Access token for a private repository. Required unless the repository is public — without it, tofu apply fails with a 404."
  type        = string
  default     = null
  sensitive   = true
}


################################################################################
# Packaged deployment (OCI worker image)
#
# Setting package_version switches this install from the classic git-clone
# model to the packaged one:
#
#   git-clone  the agent clones this repository at repository_branch into
#              base_clone_path and executes entrypoint/entrypoint from the
#              working tree. Runtime tooling (tofu) must exist on the agent
#              or be downloaded at action time.
#
#   packaged   service_definition publishes a package revision whose bill of
#              materials pins the service spec snapshot, every link spec
#              snapshot, every action, and the worker image by digest; the
#              agent association emits a package-exec channel that spawns
#              that image and runs its baked entrypoint. Tofu is baked in.
#
# Both models still register the SPECS over git — service_definition always
# fetches specs/*.json.tpl from repository_branch. The package does not
# replace that; it pins its result.
################################################################################

variable "package_version" {
  description = <<-EOT
    Semver of the package revision to publish, e.g. "0.0.1". Setting it
    enables the packaged deployment model; leaving it null (the default)
    keeps the git-clone model.

    This version is the PACKAGE's own and is independent of this
    repository's git tag: bump it on every release that changes either the
    specs or the image. Re-applying the same version with the same
    components is an idempotent no-op.

    Requires tofu_modules_ref >= v7.2.0 — the package, worker_orchestrator,
    package_slug and entrypoint variables do not exist on earlier refs.

    TWO-STEP FIRST APPLY: this service's spec sets use_default_actions, so
    the platform creates its actions server-side. On the very first apply —
    the one that CREATES the specification — those actions have no snapshot
    id yet, so the bill of materials cannot pin them. Apply once to create
    the specs, then apply again to publish a package revision that pins the
    complete set. Subsequent applies are single-step.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.package_version == null || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+", var.package_version))
    error_message = "package_version must be a semver string such as \"0.0.1\"."
  }
}

variable "image_registry" {
  description = <<-EOT
    Registry HOST of the worker image, without a repository path. Defaults to
    the ECR Public host the release workflow pushes to.

    The registry is free-form as far as nullplatform is concerned: the package
    artifact's meta is stored verbatim. What must line up is that the agent can
    actually pull from it — ECR Public needs no pull credentials, a private
    registry does.
  EOT
  type        = string
  default     = "public.ecr.aws"
}

variable "image_repository" {
  description = <<-EOT
    Repository path of the worker image inside image_registry. On ECR Public
    the registry namespace is part of the repository, which is why this is
    "nullplatform/services/..." and not just "services/..." — the release
    workflow's own split puts the host in --registry and everything else here.

    Must match the image_name the workflow pushed, prefixed by the namespace.
  EOT
  type        = string
  default     = "nullplatform/agent-plugins/services/postgresql-flexible-server"
}

variable "image_digest" {
  description = <<-EOT
    Immutable digest of the worker image, "sha256:" followed by 64 hex
    characters. Required when package_version is set.

    Read it off the GitHub release that the release workflow finalized (the
    "Artifact" table it appends), not from a local docker inspect: the
    published multi-arch index digest is what the agent pulls.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.image_digest == "" || can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "image_digest must be formatted \"sha256:<64 lowercase hex chars>\"."
  }
}

variable "package_slug" {
  description = "Slug of the package. Null (the default) uses the service specification's own slug, which is what `np package publish` would also produce — keep it that way unless there is a reason not to."
  type        = string
  default     = null
}

variable "package_default" {
  description = "Promote each published revision to the package default. Leave true unless revisions are being staged before rollout."
  type        = bool
  default     = true
}

variable "package_visible_to" {
  description = "NRNs the package and its artifact are visible to. Null (the default) means [var.nrn]."
  type        = list(string)
  default     = null
}

variable "worker_entrypoint" {
  description = <<-EOT
    Absolute path of the entrypoint INSIDE the worker image, used as the
    package-exec cmdline.

    Set explicitly rather than left to the module default. The module
    defaults to "/app/packages/<package_slug>/entrypoint", which is not
    where this repository's Dockerfile puts it — the Dockerfile does
    `COPY . /app/pkg` and sets
    NP_SCOPE_ENTRYPOINT=/app/pkg/postgresql-flexible-server/entrypoint/entrypoint.
    The worker bridge is documented as using its own baked
    NP_SCOPE_ENTRYPOINT, which would make the cmdline decorative — but
    pointing it at the real path costs nothing and is correct under either
    behaviour. Change it here and in the Dockerfile together.
  EOT
  type        = string
  default     = "/app/pkg/postgresql-flexible-server/entrypoint/entrypoint"
}
