# Terraform 1.5+ import blocks — adopt resources created outside terraform
# into state on the next apply. After the first successful apply, terraform
# silently skips imports for resources already in state, so leaving these
# in place is safe.
#
# Use case: an operator hand-created a resource (via AWS CLI or console)
# during incident response, and we want terraform to take ownership on the
# next plan/apply rather than creating a duplicate.

# Adopt a pre-existing ACM cert (us-east-1) when var.import_acm_cert_arn
# is set. Gated on use_cloudfront_edge because the target resource only
# exists when the edge module is enabled.
import {
  for_each = var.use_cloudfront_edge && var.import_acm_cert_arn != null ? toset([var.import_acm_cert_arn]) : toset([])
  to       = module.edge[0].aws_acm_certificate.main
  id       = each.value
}
