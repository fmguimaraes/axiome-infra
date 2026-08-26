output "instance_id" {
  description = "RDS instance identifier — used to scope CloudWatch alarms / event subscriptions (FR12)."
  # Use .identifier, NOT .id: under AWS provider v5 aws_db_instance.id returns the
  # DbiResourceId (db-XXXX), but CloudWatch alarm DBInstanceIdentifier dimensions and
  # aws_db_event_subscription.source_ids both require the instance *identifier* (name).
  # Passing .id made CreateEventSubscription fail with SourceNotFound (AXI-1350 alerting).
  value = aws_db_instance.this.identifier
}

output "endpoint" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "username" {
  value = aws_db_instance.this.username
}

output "password" {
  value     = random_password.db.result
  sensitive = true
}

output "connection_string" {
  description = "Master (admin) connection string. Admin/migration use only — do not publish to app runtime secrets (FR10/NFR2)."
  value       = "postgresql://${aws_db_instance.this.username}:${random_password.db.result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}?sslmode=require"
  sensitive   = true
}

output "app_runtime_username" {
  description = "Least-privilege pilot-tenant role name (FR10/NFR2). Created by db/01_pilot_tenant_app_role.sql, not by Terraform."
  value       = var.app_runtime_username
}

output "app_runtime_password" {
  value     = random_password.app_runtime.result
  sensitive = true
}

output "app_runtime_connection_string" {
  description = "Base connection string (no ?schema= param) for the least-privilege pilot-tenant role. Callers append ?schema=<svc>. This is what should reach application containers — never the master `connection_string`."
  value       = "postgresql://${var.app_runtime_username}:${random_password.app_runtime.result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}?sslmode=require"
  sensitive   = true
}
