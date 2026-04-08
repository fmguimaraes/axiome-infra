resource "scaleway_registry_namespace" "main" {
  name        = "${var.naming_prefix}-registry"
  region      = var.region
  is_public   = false
  description = "Container registry for ${var.naming_prefix}"
}
