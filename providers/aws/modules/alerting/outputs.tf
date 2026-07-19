output "sns_topic_arn" {
  description = "SNS topic ARN receiving operational alarms (FR12). Subscribe additional protocols (Slack/PagerDuty/Opsgenie via their SNS integration, SMS, etc) or wire future backup-job alarms (AXI-113) here."
  value       = aws_sns_topic.alerts.arn
}

output "acm_sns_topic_arn" {
  description = "us-east-1 SNS topic ARN receiving ACM certificate approaching-expiry notifications. null unless acm_certificate_arn was set."
  value       = try(aws_sns_topic.acm_alerts[0].arn, null)
}
