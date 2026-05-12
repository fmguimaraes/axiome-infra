output "cloudfront_domain_name" {
  description = "CloudFront distribution domain. Create a CNAME record at the registrar pointing var.fqdn at this value."
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — useful for cache invalidations: aws cloudfront create-invalidation --distribution-id <id> --paths '/*'"
  value       = aws_cloudfront_distribution.main.id
}

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate (us-east-1)."
  value       = aws_acm_certificate.main.arn
}

output "acm_validation_records" {
  description = "DNS validation records to add at the registrar. Each entry is a CNAME from `name` to `value`."
  value = [
    for opt in aws_acm_certificate.main.domain_validation_options : {
      name  = opt.resource_record_name
      type  = opt.resource_record_type
      value = opt.resource_record_value
    }
  ]
}
