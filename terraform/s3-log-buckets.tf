# =============================================================================
# S3 LOG BUCKETS - DEV & PROD
# =============================================================================

# ── Dev Logs Bucket ───────────────────────────────────────────────────────────

resource "aws_s3_bucket" "dev_logs" {
  bucket        = "retail-store-dev-logs-${random_string.suffix.result}"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name        = "retail-store-dev-logs"
    Environment = "dev"
    Purpose     = "development-application-logs"
  })
}

resource "aws_s3_bucket_versioning" "dev_logs" {
  bucket = aws_s3_bucket.dev_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dev_logs" {
  bucket = aws_s3_bucket.dev_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "dev_logs" {
  bucket = aws_s3_bucket.dev_logs.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "dev_logs" {
  bucket = aws_s3_bucket.dev_logs.id

  rule {
    id     = "dev-log-retention"
    status = "Enabled"

    filter {
      prefix = ""
    }

    # Move to cheaper storage after 30 days
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.dev_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# ── Prod Logs Bucket ──────────────────────────────────────────────────────────

resource "aws_s3_bucket" "prod_logs" {
  bucket        = "retail-store-prod-logs-${random_string.suffix.result}"
  force_destroy = false

  tags = merge(local.common_tags, {
    Name        = "retail-store-prod-logs"
    Environment = "prod"
    Purpose     = "production-application-logs"
  })
}

resource "aws_s3_bucket_versioning" "prod_logs" {
  bucket = aws_s3_bucket.prod_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "prod_logs" {
  bucket = aws_s3_bucket.prod_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "prod_logs" {
  bucket = aws_s3_bucket.prod_logs.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "prod_logs" {
  bucket = aws_s3_bucket.prod_logs.id

  rule {
    id     = "prod-log-retention"
    status = "Enabled"

    filter {
      prefix = ""
    }

    # Tiered storage: STANDARD → IA → GLACIER for cost savings
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = var.prod_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
