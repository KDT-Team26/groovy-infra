output "frontend_bucket_name" {
  description = "Private S3 bucket containing the frontend build."
  value       = aws_s3_bucket.frontend.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "frontend_domain" {
  description = "Public frontend domain."
  value       = "https://${var.frontend_domain}"
}

output "frontend_certificate_arn" {
  description = "Frontend ACM certificate ARN in us-east-1."
  value       = aws_acm_certificate_validation.frontend.certificate_arn
}