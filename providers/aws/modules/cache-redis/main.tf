# Managed Redis via AWS ElastiCache (FR5) — private subnets + data SG only (NFR7),
# CMK-encrypted at rest + TLS in transit (FR6/NFR5). Exposed to the app via REDIS_URL
# (Redis protocol = the portability seam; OVH/Scaleway provide managed Redis behind
# the same contract).

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.naming_prefix}-redis"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.naming_prefix}-redis"
  description          = "${var.naming_prefix} managed Redis (WebSocket pub/sub adapter)"
  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_clusters   = var.num_cache_clusters
  parameter_group_name = var.parameter_group_name
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = var.vpc_security_group_ids

  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true

  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  # Automated, CMK-encrypted daily snapshots (FR1/NFR1/NFR4) — the ElastiCache gap
  # in the AC1 backup matrix (RDS PITR + S3 versioning already covered).
  snapshot_retention_limit = var.snapshot_retention_days
  snapshot_window          = var.snapshot_window

  tags = var.tags
}
