# syntax=docker/dockerfile:1

# Worker image: the bridge runs the entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.1

# OpenTofu, pinned. Baking it here is the whole point of the OCI model: on the
# git-clone path do_tofu curls a release tarball into /tmp on every action,
# which puts github.com in the critical path of every create/link and leaves
# the version floating.
#
# Keep TOFU_VERSION in sync with .github/workflows/terraform.yml and with
# do_tofu's fallback.
ARG TOFU_VERSION=1.13.1

# TARGETARCH is a BuildKit built-in and is EMPTY under the legacy builder.
# Falling back to uname keeps a local verification build working.
ARG TARGETARCH
RUN set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64|amd64)  arch=amd64 ;; \
        aarch64|arm64) arch=arm64 ;; \
        *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    curl -fsSL -o /tmp/tofu.tar.gz \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.tar.gz"; \
    tar -xzf /tmp/tofu.tar.gz -C /usr/local/bin tofu; \
    rm -f /tmp/tofu.tar.gz; \
    tofu version

# Bake the service in and point the bridge at its entrypoint + service path.
# Bake the service in. --chown so the files belong to the uid this image runs
# as: `np` chmods the action script in place at runtime, and a root-owned tree
# would be read-only for the non-root user.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=azure-postgresql-flexible-server \
    NP_SERVICE_PATH=/app/pkg/postgresql-flexible-server \
    NP_SCOPE_ENTRYPOINT=/app/pkg/postgresql-flexible-server/entrypoint/entrypoint

# Drop root for the runtime. Everything above installs as root, as usual; the
# base (worker-bridge 2.0.0+) ships the app user, np on PATH and a writable
# HOME, and leaves the switch to each image. Numeric on purpose: k8s
# admission with runAsNonRoot resolves USER to a numeric id to prove it
# isn't root, and a name doesn't satisfy that check.
USER 10001:10001
