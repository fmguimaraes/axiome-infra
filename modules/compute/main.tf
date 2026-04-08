resource "scaleway_container_namespace" "main" {
  name        = "${var.naming_prefix}-containers"
  region      = var.region
  description = "Container namespace for ${var.naming_prefix}"
}

resource "scaleway_container" "backend" {
  name            = "${var.naming_prefix}-backend"
  namespace_id    = scaleway_container_namespace.main.id
  region          = var.region
  registry_image  = "${var.registry_endpoint}/backend:latest"
  port            = 3000
  cpu_limit       = var.backend_cpu_limit
  memory_limit    = var.backend_memory_limit
  min_scale       = var.backend_min_scale
  max_scale       = var.backend_max_scale
  privacy         = "public"
  protocol        = "http1"
  http_option     = "redirected"
  deploy          = false

  environment_variables = {
    NODE_ENV = "production"
    PORT     = "3000"
  }
}

resource "scaleway_container" "biocompute" {
  name            = "${var.naming_prefix}-biocompute"
  namespace_id    = scaleway_container_namespace.main.id
  region          = var.region
  registry_image  = "${var.registry_endpoint}/biocompute:latest"
  port            = 8000
  cpu_limit       = var.biocompute_cpu_limit
  memory_limit    = var.biocompute_memory_limit
  min_scale       = var.biocompute_min_scale
  max_scale       = var.biocompute_max_scale
  privacy         = "private"
  protocol        = "http1"
  deploy          = false

  environment_variables = {
    PYTHON_ENV = "production"
    PORT       = "8000"
  }
}

resource "scaleway_container" "frontend" {
  count = var.enable_frontend_container ? 1 : 0

  name            = "${var.naming_prefix}-frontend"
  namespace_id    = scaleway_container_namespace.main.id
  region          = var.region
  registry_image  = "${var.registry_endpoint}/frontend:latest"
  port            = 80
  cpu_limit       = 500
  memory_limit    = 256
  min_scale       = 1
  max_scale       = 2
  privacy         = "public"
  protocol        = "http1"
  http_option     = "redirected"
  deploy          = false
}
