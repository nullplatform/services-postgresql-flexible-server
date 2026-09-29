# Install — registering postgresql-flexible-server

Registers the service specification, its `connect` link specification, and the
agent association (notification channel) on a nullplatform account. Run once
per namespace. It creates no Azure infrastructure — that happens per service
instance at `create` time.

Unlike the AWS services there is **no `requirements/` module**: the AssumeRole
permissions model is AWS-only. Grant permissions on the Azure side instead —
see "Azure permissions" in the [repository README](../../../README.md).

## Choosing `tofu_modules_ref`

`tofu_modules_ref` has no default on purpose — it is not this implementation's
decision. Before applying, check what currently exists:

```bash
git ls-remote --tags https://github.com/nullplatform/tofu-modules
```

As of this writing the newest tag is `v7.3.0` (identical to `main` at the same
commit); do not assume this is still true, and do not reuse the ref another
service's install pins (e.g. `services-postgresql-aurora` pins `v4.5.1`, which
predates `git_provider`, `local_specs_path`, `repository_ref_type`, and the
`repository_branch` validation described below — these repos are mid-migration
from release branches to tags, and older refs simply lack newer variables).

## Choosing `repository_branch`

`repository_branch` is also required, with no default. It is the pinned ref of
**this** repository (`services-postgresql-flexible-server`), not of `tofu-modules`. That has
no default here as **our own policy** — pin an immutable ref, don't track a
moving branch — not because every `tofu_modules_ref` enforces it: at
`tofu-modules` v7.2.0+ the `service_definition` module itself also validates
this and rejects `"main"`, `"master"`, `"head"`, and `"latest"`
(case-insensitively), even when `git_provider = "local"` (validated but never
fetched); at v7.1.0 and earlier it does not — `repository_branch` there simply
defaults to `"main"`. Don't rely on the module to catch this if you pin an
older ref; the lack of a default in this file is the actual guardrail either
way. Pair it with `repository_ref_type` (`"tags"` by default here, or
`"heads"` for a branch name, or `""` for a raw commit SHA — see that
variable's description in `variables.tf` for why `"tags"` is pinned explicitly
rather than left to the module's own default). If this repository has no tags
yet, cut one before using remote/production mode, or set
`repository_ref_type = "heads"` and point at a real branch other than `main`.

## Choosing `base_clone_path`

Required in the git-clone model only — the packaged model builds no clone path
at all, and a precondition in `main.tf` enforces which one applies. It has no
default, and it is the one that fails **silently** if wrong:
the channel registers fine, and the mistake only surfaces later as an agent
error like "command not found in any allowed paths" on the first real
notification. The right value tracks the deployed **agent image's** home
directory, not `tofu_modules_ref` — and the two are versioned independently.
Don't copy a value from this repo or from the module's own docs: confirm the
actual `$HOME` of the agent pod/process that will run this service (e.g.
`kubectl exec <agent-pod> -- env | grep HOME` for a Kubernetes agent). As
reference points only (not defaults to copy), the `service_definition_agent_association`
module's own convenience default for this has itself changed across refs:
`"/root/.np"` at `tofu-modules` v7.1.0 and earlier (a root-user agent image),
`"/home/agent/.np"` from v7.2.0 onward (a non-root `agent`-user image). For a
local (host-runtime) agent started via `np-agent -runtime host`, it is
normally `pathexpand("~/.np")` — see the repo README's "End-to-end testing".

## Choosing a deployment model

This install registers the service in one of two shapes, selected by whether
`package_version` is set.

**git-clone** (leave `package_version` unset) — the agent clones this repository
at `repository_branch` into `base_clone_path` and runs `entrypoint/entrypoint`
from the working tree. Requires `base_clone_path` to match the agent image's
real home, and the agent must be able to reach git. OpenTofu is not in the
standard agent image, so `do_tofu` downloads it into `/tmp` on every action.

**packaged** (set `package_version`) — `service_definition` publishes a package
revision whose bill of materials pins the service spec snapshot, every link
spec snapshot, every action, and the worker image by digest; the association
emits a `package-exec` channel and the agent runs the image's baked entrypoint,
with OpenTofu already in it. Needs `tofu_modules_ref >= v7.2.0`, an image
published by the release workflow, and `AcrPull` (or the registry equivalent)
for the agent's identity.

Both models fetch the SPECS over git either way — `service_definition` always
reads `specs/*.json.tpl` from `repository_branch` at apply time. The package
does not replace that fetch; it pins its result.

The packaged model is the recommended one — see "How to register this service
in nullplatform" in the repository README. Its first apply is TWO steps: this spec uses `use_default_actions`,
so on the apply that CREATES the specification the platform-side actions have
no snapshot id yet and cannot be pinned into the bill of materials. Apply once
to create the specs, then apply again to publish a complete revision.

## Local iteration (recommended first)

Reads the specs off your filesystem, so you can change them and re-apply
without pushing anything.

```bash
cp -r postgresql-flexible-server/specs/install/azure /path/to/your/infra/postgresql-flexible-server
cd /path/to/your/infra/postgresql-flexible-server
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # set nrn, np_api_key, tofu_modules_ref, tags_selectors,
                           # repository_branch, git_provider = "local",
                           # local_specs_path, base_clone_path

tofu init
tofu plan      # review, then apply
tofu apply
```

## Remote (production)

Set `git_provider = "github"` (the default), push this repository, cut a tag,
and push this repository. `repository_token` is only needed if the repository
is private; this one is public, so leave it unset.

## Constraints that cause silent failures

- `nrn` must be identical in both modules, or actions fail with
  "There is not a channel for the given parameters".
- `tags_selectors` must match the agent's `-tags` exactly, or notifications
  are created but never routed to an agent — the service looks registered and
  simply never runs.
- Confirm `tofu_modules_ref` against the repository. These repos are migrating
  from release branches to tags, so a ref that worked for another service may
  not exist here.
- `repository_branch` may not be `main`/`master`/`head`/`latest` — this is our
  own required-with-no-default policy; the module only enforces it too at
  `tofu-modules` v7.2.0+, not at every ref.
- `base_clone_path` must match the deployed agent image's actual home
  directory. A wrong value produces no error at `apply` — only a failed
  notification later, with an "allowed paths" error at the agent.

Verify afterwards:

```bash
/np-api fetch-api "/service_specification?nrn=<nrn>&show_descendants=true" | jq '[.[] | {slug, name}]'
```
