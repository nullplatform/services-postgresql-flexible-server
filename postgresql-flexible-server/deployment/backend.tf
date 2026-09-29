# Backend configuration is supplied entirely at "tofu init" time by
# build_context via -backend-config flags. This file is static and committed:
# generating it at runtime races when two actions execute concurrently.
terraform {
  backend "azurerm" {}
}
