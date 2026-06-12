output "vpc_id" {
  value = local.vpc_id
}

output "public_subnet_ids" {
  value = local.public_subnet_ids
}

output "private_subnet_ids" {
  value = local.private_subnet_ids
}

output "edge_security_group_id" {
  value = local.edge_security_group_id
}

output "app_security_group_id" {
  value = local.app_security_group_id
}

output "data_security_group_id" {
  value = local.data_security_group_id
}
