output "instance_id" {
  value = scaleway_instance_server.main.id
}

output "public_ip" {
  value = scaleway_instance_ip.main.address
}

output "instance_name" {
  value = scaleway_instance_server.main.name
}
