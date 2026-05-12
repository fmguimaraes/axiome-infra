variable "fqdn" {
  description = "Fully-qualified domain name CloudFront fronts (e.g. dev.axiomebio.com)."
  type        = string
}

variable "origin_ip" {
  description = "Lightsail static IPv4 of the origin VM that Caddy listens on. Used to derive the AWS-managed reverse DNS hostname that CloudFront uses as its origin (CloudFront rejects raw IPs as origin domain names)."
  type        = string
}

variable "aws_region" {
  description = "AWS region of the Lightsail VM, used to construct the EC2-style reverse DNS hostname (ec2-A-B-C-D.<region>.compute.amazonaws.com) that CloudFront uses as its origin domain."
  type        = string
}

variable "origin_protocol" {
  description = "Protocol CloudFront uses to talk to the origin. 'http-only' is recommended when Caddy on the VM has no public-CA cert (the origin leg is over AWS network)."
  type        = string
  default     = "http-only"
  validation {
    condition     = contains(["http-only", "https-only", "match-viewer"], var.origin_protocol)
    error_message = "origin_protocol must be one of: http-only, https-only, match-viewer."
  }
}

variable "tags" {
  description = "Tags applied to ACM cert and CloudFront distribution."
  type        = map(string)
  default     = {}
}
