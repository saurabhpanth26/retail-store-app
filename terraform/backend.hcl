# Terraform S3 Backend Configuration
#
# Usage:
#   terraform init -backend-config=backend.hcl
#
# Run scripts/setup-tf-backend.sh ONCE before the first terraform init
# to create the S3 bucket.
#
# Native S3 locking (Terraform >= 1.10) — no DynamoDB required.
# Terraform writes a .tflock file directly in S3 to coordinate locking.

bucket       = "retail-store-tfstate-879385477302-us-west-2"
key          = "retail-store/eks/terraform.tfstate"
region       = "us-west-2"
encrypt      = true
use_lockfile = true
