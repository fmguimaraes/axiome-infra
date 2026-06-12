# Customer-managed key (CMK) for data-at-rest encryption — FR6 / NFR5 / AC7.
# One platform CMK covers RDS, the event store, S3 buckets, EBS volumes
# (Redis/RabbitMQ), the secrets store, and backups. Rotation enabled.

resource "aws_kms_key" "data" {
  description             = "${var.naming_prefix} data-at-rest CMK (RDS, event store, S3, volumes, secrets, backups)"
  deletion_window_in_days = var.environment == "production" ? 30 : 7
  enable_key_rotation     = var.enable_key_rotation

  tags = merge(var.tags, { Purpose = "data-at-rest-cmk" })
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.naming_prefix}-data"
  target_key_id = aws_kms_key.data.key_id
}
