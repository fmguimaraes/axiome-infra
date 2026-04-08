output "backend_endpoint" {
  description = "Backend public endpoint"
  value       = scaleway_container.backend.domain_name
}

output "biocompute_private_endpoint" {
  description = "Biocompute private endpoint"
  value       = scaleway_container.biocompute.domain_name
}

output "frontend_endpoint" {
  description = "Frontend endpoint (if container mode)"
  value       = var.enable_frontend_container ? scaleway_container.frontend[0].domain_name : ""
}

output "backend_container_id" {
  description = "Backend container ID"
  value       = scaleway_container.backend.id
}

output "biocompute_container_id" {
  description = "Biocompute container ID"
  value       = scaleway_container.biocompute.id
}
