output "service_specification_id" {
  description = "ID of the registered postgresql-flexible-server service specification."
  value       = module.service_definition.service_specification_id
}

output "service_specification_slug" {
  description = "Slug of the registered postgresql-flexible-server service specification."
  value       = module.service_definition.service_specification_slug
}

################################################################################
# Package outputs — null in the git-clone model (package_version unset).
################################################################################

output "deployment_model" {
  description = "Which model this install registered: \"packaged\" (package-exec channel + OCI worker image) or \"git-clone\"."
  value       = local.packaged ? "packaged" : "git-clone"
}

output "package_id" {
  description = "ID of the package published from this service definition."
  value       = module.service_definition.package_id
}

output "package_published_revision_id" {
  description = "Revision UUID published for package_version. Changes on every version bump; unchanged when re-applying the same version with the same components."
  value       = module.service_definition.package_published_revision_id
}

output "package_default_version" {
  description = "The package's default version after apply."
  value       = module.service_definition.package_default_version
}

output "worker_image" {
  description = "Pinned worker image this install bound the package to, as registry/repository@digest."
  value       = local.packaged ? "${var.image_registry}/${var.image_repository}@${var.image_digest}" : null
}
