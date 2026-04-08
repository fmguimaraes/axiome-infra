output "private_network_id" {
  description = "ID of the private network"
  value       = scaleway_vpc_private_network.main.id
}
