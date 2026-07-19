# Operational alarms (FR12 / AC12) — actionable pages for disk capacity, EC2/RDS/
# ElastiCache health, RDS automated-backup failure, and (when fronted by CloudFront)
# ACM certificate approaching-expiry. Envs that terminate TLS via Caddy/Let's Encrypt
# on the compute host instead (no ACM cert, e.g. production — see providers/RUNBOOK.md
# §S8) get TLS-cert-expiry coverage from the portable Prometheus/Alertmanager stack's
# blackbox_exporter probe instead (observability/alerts.yml TLSCertExpiringSoon).
#
# Every alarm here targets a resource that already exists. Store-specific
# backup-failure alarms for Mongo/EBS land with that backup automation itself
# (AXI-113 / FR1) — wire them to `sns_topic_arn` (output) when it exists; RDS is the
# only store with automated backups today (backup_retention_period).

resource "aws_sns_topic" "alerts" {
  name              = "${var.naming_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------- EC2 (disk capacity + host health) ----------------

resource "aws_cloudwatch_metric_alarm" "ec2_disk_used_percent" {
  count = var.ec2_instance_id != "" ? 1 : 0

  alarm_name        = "${var.naming_prefix}-ec2-disk-used-percent"
  alarm_description = "Root volume disk usage above ${var.disk_threshold_percent}% (FR12) — investigate before the host stops accepting writes."
  namespace         = "CWAgent"
  metric_name       = "disk_used_percent"
  dimensions = {
    InstanceId = var.ec2_instance_id
    path       = "/"
    fstype     = "ext4"
  }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.disk_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching" # the agent going silent is itself actionable
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ec2_status_check_failed" {
  count = var.ec2_instance_id != "" ? 1 : 0

  alarm_name          = "${var.naming_prefix}-ec2-status-check-failed"
  alarm_description   = "EC2 system/instance status check failed (FR12) — host- or hypervisor-level failure."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = var.ec2_instance_id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

# ---------------- RDS (storage + automated-backup failure) ----------------

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  count = var.rds_instance_id != "" ? 1 : 0

  alarm_name          = "${var.naming_prefix}-rds-free-storage-low"
  alarm_description   = "RDS free storage below 2 GiB (FR12) — PITR backups and writes fail once storage is exhausted."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 2147483648 # 2 GiB
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

# RDS emits "backup" category events (including failures) independently of any
# CloudWatch metric — the real signal for automated-backup success/failure on the one
# store that has automated backups today.
resource "aws_db_event_subscription" "rds_backup" {
  count = var.rds_instance_id != "" ? 1 : 0

  name             = "${var.naming_prefix}-rds-backup-events"
  sns_topic        = aws_sns_topic.alerts.arn
  source_type      = "db-instance"
  source_ids       = [var.rds_instance_id]
  event_categories = ["backup"]
  tags             = var.tags
}

# ---------------- ElastiCache ----------------

resource "aws_cloudwatch_metric_alarm" "redis_engine_cpu_high" {
  count = var.redis_replication_group_id != "" ? 1 : 0

  alarm_name          = "${var.naming_prefix}-redis-engine-cpu-high"
  alarm_description   = "ElastiCache engine CPU above 90% (FR12)."
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  dimensions          = { ReplicationGroupId = var.redis_replication_group_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

# ---------------- ACM certificate expiry (CloudFront-fronted envs only) ----------------
# ACM auto-renews, but silently stops if domain validation lapses — this EventBridge
# notification is the only signal for that. Must live in us-east-1: that's where
# CloudFront's ACM cert (and its expiry events) live (see modules/edge). A dedicated
# SNS topic because cross-region EventBridge -> SNS targets aren't supported, and the
# data CMK is regional (so this topic uses the AWS-managed SNS key, not the CMK).

resource "aws_sns_topic" "acm_alerts" {
  count    = var.acm_certificate_arn != "" ? 1 : 0
  provider = aws.us_east_1

  name = "${var.naming_prefix}-acm-cert-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "acm_alerts_email" {
  count    = var.acm_certificate_arn != "" && var.alert_email != "" ? 1 : 0
  provider = aws.us_east_1

  topic_arn = aws_sns_topic.acm_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_event_rule" "acm_cert_expiring" {
  count    = var.acm_certificate_arn != "" ? 1 : 0
  provider = aws.us_east_1

  name = "${var.naming_prefix}-acm-cert-expiring"
  event_pattern = jsonencode({
    source      = ["aws.acm"]
    detail-type = ["ACM Certificate Approaching Expiration"]
    resources   = [var.acm_certificate_arn]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "acm_cert_expiring_sns" {
  count    = var.acm_certificate_arn != "" ? 1 : 0
  provider = aws.us_east_1

  rule      = aws_cloudwatch_event_rule.acm_cert_expiring[0].name
  target_id = "sns"
  arn       = aws_sns_topic.acm_alerts[0].arn
}

resource "aws_sns_topic_policy" "acm_alerts" {
  count    = var.acm_certificate_arn != "" ? 1 : 0
  provider = aws.us_east_1

  arn = aws_sns_topic.acm_alerts[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.acm_alerts[0].arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.acm_cert_expiring[0].arn } }
    }]
  })
}
