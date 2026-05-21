# =============================================================================
# INPUT VARIABLES
# =============================================================================

variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "retail-store"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "argocd_namespace" {
  description = "Namespace to install ArgoCD"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "5.51.6"
}

variable "enable_single_nat_gateway" {
  description = "Use single NAT gateway to reduce costs (not recommended for production)"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Kept for reference — monitoring is now always deployed via monitoring.tf"
  type        = bool
  default     = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password — stored in kubernetes secret grafana-admin-secret"
  type        = string
  default     = "admin123"
  sensitive   = true
}

variable "dev_log_retention_days" {
  description = "Number of days to retain dev logs in S3 before expiry"
  type        = number
  default     = 60
}

variable "prod_log_retention_days" {
  description = "Number of days to retain prod logs in S3 before expiry"
  type        = number
  default     = 365
}

variable "domain_name" {
  description = "Root domain name for the application (e.g. saurabh-devops.in). Used for ACM certificate and Route53 hosted zone."
  type        = string
  default     = "saurabh-devops.in"
}
