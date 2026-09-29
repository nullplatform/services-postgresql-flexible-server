# syntax=docker/dockerfile:1
#
# postgresql-flexible-server service worker image.
#
# The nullplatform worker bridge dials over gRPC and runs the baked bash
# entrypoint on each package-exec action. This image adds the one tool the
# Azure workflows need that the lean base does not carry — OpenTofu — and
# bakes the service in, so the notification channel needs no cmdline of its own.
#
# Deliberately NO azure-cli and NO psql. The service resolves its identity
# from the nullplatform cloud-providers provider and lets the azurerm provider
# authenticate from ARM_*; roles and grants are managed by the
# cyrilgdn/postgresql Terraform provider over TLS. Nothing under scripts/azure/
# shells out to a database or cloud CLI. bash, jq, np and curl ship in the base.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:1.1.1

# OpenTofu, pinned. Baking it here is the whole point of the OCI model: on the
# git-clone path do_tofu curls a release tarball into /tmp on every action,
# which puts github.com in the critical path of every create/link and leaves
# the version floating.
#
# Keep TOFU_VERSION in sync with .github/workflows/terraform.yml and with
# do_tofu's fallback.
ARG TOFU_VERSION=1.10.10

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
COPY . /app/pkg
ENV NP_PACKAGE_NAME=postgresql-flexible-server \
    NP_SERVICE_PATH=/app/pkg/postgresql-flexible-server \
    NP_SCOPE_ENTRYPOINT=/app/pkg/postgresql-flexible-server/entrypoint/entrypoint
