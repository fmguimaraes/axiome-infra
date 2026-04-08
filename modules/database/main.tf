resource "scaleway_rdb_instance" "postgres" {
  name           = "${var.naming_prefix}-postgres"
  node_type      = var.postgres_node_type
  engine         = "PostgreSQL-15"
  is_ha_cluster  = false
  disable_backup = false

  volume_type       = "lssd"
  volume_size_in_gb = var.postgres_volume_size

  private_network {
    pn_id = var.private_network_id
  }

  tags = var.tags
}

resource "scaleway_rdb_database" "main" {
  instance_id = scaleway_rdb_instance.postgres.id
  name        = "axiome"
}

resource "scaleway_mongodb_instance" "main" {
  name      = "${var.naming_prefix}-mongodb"
  version   = "7.0.12"
  node_type = var.mongodb_node_type
  node_number = 1

  tags = var.tags
}
