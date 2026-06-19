output "vpc_id" {
  value = scaleway_vpc.this.id
}

output "private_network_id" {
  value = scaleway_vpc_private_network.this.id
}

# Scaleway has no AWS-style subnet objects; the private network is the isolation unit.
output "public_subnet_ids" {
  value = []
}

output "private_subnet_ids" {
  value = [scaleway_vpc_private_network.this.id]
}

output "edge_security_group_id" {
  value = scaleway_instance_security_group.edge.id
}

output "app_security_group_id" {
  value = scaleway_instance_security_group.app.id
}

output "data_security_group_id" {
  value = scaleway_instance_security_group.data.id
}
