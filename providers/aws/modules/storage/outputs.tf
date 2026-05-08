output "artifacts_bucket_name" {
  value = aws_s3_bucket.artifacts.id
}

output "artifacts_bucket_arn" {
  value = aws_s3_bucket.artifacts.arn
}

output "uploads_bucket_name" {
  value = aws_s3_bucket.uploads.id
}

output "uploads_bucket_arn" {
  value = aws_s3_bucket.uploads.arn
}

output "system_bucket_name" {
  value = aws_s3_bucket.system.id
}

output "system_bucket_arn" {
  value = aws_s3_bucket.system.arn
}

output "all_bucket_arns" {
  value = [
    aws_s3_bucket.artifacts.arn,
    "${aws_s3_bucket.artifacts.arn}/*",
    aws_s3_bucket.uploads.arn,
    "${aws_s3_bucket.uploads.arn}/*",
    aws_s3_bucket.system.arn,
    "${aws_s3_bucket.system.arn}/*",
  ]
}
