locals {
  caddyfile = templatefile("${path.module}/../../cloud-init/Caddyfile.tftpl", {
    fqdn = var.fqdn
  })

  docker_compose_yml = file("${path.module}/../../cloud-init/docker-compose.yml")

  cloud_init = templatefile("${path.module}/../../cloud-init/init.sh.tftpl", {
    region       = var.region
    fqdn         = var.fqdn
    environment  = var.environment
    project_name = var.naming_prefix

    registry_endpoint = var.registry_endpoint
    registry_password = var.registry_credentials

    postgres_url = var.postgres_url
    mongodb_url  = var.mongodb_url

    s3_endpoint         = var.s3_endpoint
    s3_region           = var.s3_region
    s3_artifacts_bucket = var.s3_artifacts_bucket
    s3_uploads_bucket   = var.s3_uploads_bucket
    s3_system_bucket    = var.s3_system_bucket
    s3_access_key       = var.s3_access_key
    s3_secret_key       = var.s3_secret_key

    backend_image_tag    = var.backend_image_tag
    biocompute_image_tag = var.biocompute_image_tag
    frontend_image_tag   = var.frontend_image_tag

    docker_compose_yml = local.docker_compose_yml
    caddyfile          = local.caddyfile

    cockpit_push_url = var.cockpit_push_url
    cockpit_token    = var.cockpit_token
  })
}

resource "scaleway_instance_ip" "main" {
  zone = var.zone
  type = "routed_ipv4"
}

resource "scaleway_instance_server" "main" {
  name  = "${var.naming_prefix}-vm"
  type  = var.instance_type
  image = var.instance_image
  zone  = var.zone
  ip_id = scaleway_instance_ip.main.id
  # IPv6 is governed by the attached routed IP (scaleway_instance_ip type
  # routed_ipv4); the legacy `enable_ipv6` argument was removed in provider 2.x.

  root_volume {
    size_in_gb = var.root_volume_size_gb
  }

  user_data = {
    cloud-init = local.cloud_init
  }

  tags = var.tags
}
