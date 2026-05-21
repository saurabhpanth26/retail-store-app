# =============================================================================
# MONITORING STACK - Prometheus · Loki · Grafana Alloy · Grafana
# =============================================================================

locals {
  monitoring_ns  = "monitoring"
  # Route Loki to the dev or prod bucket based on var.environment
  loki_s3_bucket = var.environment == "prod" ? aws_s3_bucket.prod_logs.bucket : aws_s3_bucket.dev_logs.bucket
  loki_s3_arn    = var.environment == "prod" ? aws_s3_bucket.prod_logs.arn    : aws_s3_bucket.dev_logs.arn
  # Strip the https:// prefix for IRSA condition keys
  oidc_host      = replace(module.retail_app_eks.cluster_oidc_issuer_url, "https://", "")
}

# =============================================================================
# IAM — IRSA ROLE FOR LOKI S3 ACCESS
# =============================================================================

data "aws_iam_policy_document" "loki_s3" {
  statement {
    sid     = "LokiS3Objects"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.loki_s3_arn}/*"]
  }

  statement {
    sid     = "LokiS3Bucket"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.loki_s3_arn]
  }
}

resource "aws_iam_policy" "loki_s3" {
  name   = "LokiS3Policy-${local.cluster_name}"
  policy = data.aws_iam_policy_document.loki_s3.json
  tags   = local.common_tags
}

data "aws_iam_policy_document" "loki_irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.retail_app_eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${local.monitoring_ns}:loki"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "loki_irsa" {
  name               = "loki-irsa-${local.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.loki_irsa_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "loki_s3" {
  role       = aws_iam_role.loki_irsa.name
  policy_arn = aws_iam_policy.loki_s3.arn
}

# =============================================================================
# KUBERNETES — GRAFANA ADMIN SECRET
# =============================================================================

resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin-secret"
    namespace = local.monitoring_ns
  }

  data = {
    "admin-user"     = "admin"
    "admin-password" = var.grafana_admin_password
  }

  type = "Opaque"

  # Namespace is created by the Prometheus helm_release below (create_namespace = true)
  depends_on = [helm_release.prometheus]
}

# =============================================================================
# HELM — 1/4  kube-prometheus-stack
# =============================================================================

resource "helm_release" "prometheus" {
  name             = "monitoring"
  namespace        = local.monitoring_ns
  create_namespace = true

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "67.4.0"

  values  = [file("${path.module}/../argocd/montioring/01-prometheus-values.yaml")]
  timeout = 600
  wait    = true

  depends_on = [time_sleep.wait_for_cluster]
}

# =============================================================================
# HELM — 2/4  Loki
# =============================================================================

resource "helm_release" "loki" {
  name      = "loki"
  namespace = local.monitoring_ns

  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.29.0"

  values  = [file("${path.module}/../argocd/montioring/02-loki-values.yaml")]
  timeout = 600
  wait    = true

  # ── Inject Terraform-managed S3 bucket + region ──────────────────────────
  set {
    name  = "loki.storage.bucketNames.chunks"
    value = local.loki_s3_bucket
  }
  set {
    name  = "loki.storage.bucketNames.ruler"
    value = local.loki_s3_bucket
  }
  set {
    name  = "loki.storage.bucketNames.admin"
    value = local.loki_s3_bucket
  }
  set {
    name  = "loki.storage.s3.region"
    value = var.aws_region
  }

  # ── Wire IRSA role to the Loki service account ───────────────────────────
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "loki"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.loki_irsa.arn
  }

  depends_on = [helm_release.prometheus, aws_iam_role_policy_attachment.loki_s3]
}

# =============================================================================
# HELM — 3/4  Grafana Alloy
# =============================================================================

resource "helm_release" "alloy" {
  name      = "alloy"
  namespace = local.monitoring_ns

  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "0.12.0"

  values  = [file("${path.module}/../argocd/montioring/03-alloy-values.yaml")]
  timeout = 600
  wait    = true

  depends_on = [helm_release.loki]
}

# =============================================================================
# HELM — 4/4  Grafana
# =============================================================================

resource "helm_release" "grafana" {
  name      = "grafana"
  namespace = local.monitoring_ns

  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = "8.10.4"

  values  = [file("${path.module}/../argocd/montioring/04-grafana-values.yaml")]
  timeout = 600
  wait    = true

  depends_on = [kubernetes_secret.grafana_admin, helm_release.alloy]
}
