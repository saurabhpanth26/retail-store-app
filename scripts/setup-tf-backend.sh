#!/usr/bin/env bash
# =============================================================================
# Terraform Backend Bootstrap
#
# Creates the S3 bucket for remote state.
# Native locking via .tflock file (Terraform >= 1.10) — no DynamoDB needed.
#
# Run this ONCE before your first `terraform init`.
#
# Usage:
#   chmod +x scripts/setup-tf-backend.sh
#   ./scripts/setup-tf-backend.sh
#
# Override region:
#   AWS_REGION=eu-west-1 ./scripts/setup-tf-backend.sh
# =============================================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-south-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="retail-store-tfstate-${AWS_ACCOUNT_ID}-${AWS_REGION}"

echo "============================================="
echo " Terraform Backend Bootstrap"
echo "============================================="
echo " Bucket : ${BUCKET_NAME}"
echo " Region : ${AWS_REGION}"
echo " Account: ${AWS_ACCOUNT_ID}"
echo " Locking: native S3 (.tflock) — no DynamoDB"
echo "============================================="
echo ""

# ── S3 bucket ─────────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "✅ S3 bucket already exists: ${BUCKET_NAME}"
else
  echo "Creating S3 bucket: ${BUCKET_NAME} ..."

  if [ "${AWS_REGION}" == "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${AWS_REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}"
  fi

  # Versioning — recover from accidental state corruption
  aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  # Server-side encryption (AES-256)
  aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" },
        "BucketKeyEnabled": true
      }]
    }'

  # Block all public access
  aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  # Expire old non-current state versions after 90 days
  aws s3api put-bucket-lifecycle-configuration \
    --bucket "${BUCKET_NAME}" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "expire-old-state-versions",
        "Status": "Enabled",
        "Filter": { "Prefix": "" },
        "NoncurrentVersionExpiration": { "NoncurrentDays": 90 }
      }]
    }'

  echo "✅ S3 bucket created: ${BUCKET_NAME}"
fi

# ── Update backend.hcl with resolved values ───────────────────────────────────
BACKEND_FILE="$(dirname "$0")/../terraform/backend.hcl"
if [ -f "${BACKEND_FILE}" ]; then
  sed -i.bak "s|^bucket.*|bucket       = \"${BUCKET_NAME}\"|" "${BACKEND_FILE}"
  sed -i.bak "s|^region.*|region       = \"${AWS_REGION}\"|"  "${BACKEND_FILE}"
  rm -f "${BACKEND_FILE}.bak"
  echo "✅ Updated terraform/backend.hcl"
fi

echo ""
echo "============================================="
echo " Bootstrap complete! Next steps:"
echo "============================================="
echo ""
echo "  cd terraform"
echo "  terraform init -backend-config=backend.hcl"
echo "  terraform plan"
echo "  terraform apply"
echo ""
