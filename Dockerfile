# syntax=docker/dockerfile:1
# Worker image: the bridge runs the entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:1.1.1

COPY . /app/pkg
ENV NP_PACKAGE_NAME=my-service \
    NP_SERVICE_PATH=/app/pkg/my-service \
    NP_SCOPE_ENTRYPOINT=/app/pkg/my-service/entrypoint/entrypoint
