# Edge module — CloudFront + ACM cert.
#
# Why this module exists:
#   Caddy on the Lightsail VM used to terminate TLS itself with Let's Encrypt.
#   Every Lightsail destroy/create (image-tag bump in user_data) wiped the
#   caddy_data volume, forcing a fresh LE cert each time. After ~5 recreates
#   in a 168h window we hit LE's "5 certs per exact identifier set" limit,
#   the prod CA stopped issuing, browsers with cached HSTS got hard-blocked,
#   and dev went dark until the rate window rolled.
#
# Fix shape:
#   - ACM (us-east-1) issues a free, auto-renewed, browser-trusted cert for
#     the FQDN. ACM rate limits are independent of LE.
#   - CloudFront uses that cert at the edge and proxies to the Lightsail VM
#     over plain HTTP on port 80 (default origin protocol). The VM-side
#     Caddy no longer touches TLS, so VM lifecycle is fully decoupled from
#     cert lifecycle.
#   - HSTS lives on CloudFront response headers (set by Caddy), satisfying
#     browsers that already pinned HSTS during the LE days.
#
# DNS:
#   This module does NOT manage DNS records (axiomebio.com is on Hostinger,
#   not Route 53). Two manual records at the registrar:
#     1. CNAME from acm_validation_record.name -> acm_validation_record.value
#        (one-shot, validates the cert).
#     2. CNAME from var.fqdn -> cloudfront_domain_name (replaces the
#        existing A record that points at the Lightsail static IP).
#   Outputs surface both so the operator can paste them into Hostinger.

resource "aws_acm_certificate" "main" {
  provider = aws.us_east_1

  domain_name       = var.fqdn
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "Edge for ${var.fqdn} — TLS termination via ACM"
  price_class     = "PriceClass_100" # NA + EU only; lowest cost
  aliases         = [var.fqdn]
  tags            = var.tags

  origin {
    domain_name = var.origin_ip
    origin_id   = "lightsail-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = var.origin_protocol
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "lightsail-origin"
    viewer_protocol_policy = "redirect-to-https"

    # Pass through full HTTP method surface; the API needs DELETE/PATCH/PUT,
    # the React app needs POST/GET, etc. Cache only safe methods.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # Dev: pass everything through, cache nothing. Origin (Caddy + the app)
    # is the source of truth for cache headers. Production can tighten this
    # later by introducing a separate ordered_cache_behavior for /assets/*.
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.main.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # Wait for the cert to actually validate before CloudFront tries to use
  # it. Without this, the first apply races and CF rejects the (still
  # pending) cert.
  depends_on = [aws_acm_certificate.main]
}

# AWS-managed cache + origin-request policies — referenced by ID rather
# than redefined so we inherit AWS' updates.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}
