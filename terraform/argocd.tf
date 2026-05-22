# =============================================================================
# ARGOCD INSTALLATION AND CONFIGURATION
# =============================================================================

# Wait for the cluster and add-ons to be ready
resource "time_sleep" "wait_for_cluster" {
  create_duration = "30s"
  depends_on = [
    module.retail_app_eks,
    module.eks_addons
  ]
}

# =============================================================================
# ARGOCD HELM INSTALLATION
# =============================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.argocd_namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
        ingress = {
          enabled = false
        }
        extraArgs = ["--insecure"]
      }

      controller = {
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }

      repoServer = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      redis = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "128Mi" }
        }
      }
    })
  ]

  depends_on = [time_sleep.wait_for_cluster]
}

# =============================================================================
# WAIT FOR ARGOCD TO BE READY
# =============================================================================

resource "time_sleep" "wait_for_argocd" {
  create_duration = "60s"
  depends_on      = [helm_release.argocd]
}

# =============================================================================
# PRIVATE REPOSITORY CREDENTIALS
# ArgoCD reads this secret automatically — label argocd.argoproj.io/secret-type
# tells it this is a repo credential, not a generic secret.
# =============================================================================

resource "kubernetes_secret" "argocd_repo" {
  metadata {
    name      = "private-repo-creds"
    namespace = var.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.repo_url
    username = var.github_username
    password = var.github_token
  }

  type = "Opaque"

  depends_on = [time_sleep.wait_for_argocd]
}

# =============================================================================
# DEPLOY ARGOCD APPLICATIONS
# Placeholders REPO_URL and REPO_BRANCH are substituted at apply time using sed.
# This keeps the YAML files clean in git and avoids storing the repo URL
# in multiple places — change var.repo_url once and all apps update.
# =============================================================================

resource "null_resource" "argocd_apps" {
  depends_on = [kubernetes_secret.argocd_repo]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = <<-EOT
      set -e
      REPO_URL="${var.repo_url}"
      DEV_BRANCH="${var.dev_branch}"
      PROD_BRANCH="${var.prod_branch}"
      BASE="${path.module}/../argocd"

      echo "Updating kubeconfig for EKS cluster..."
      aws eks update-kubeconfig \
        --name "${local.cluster_name}" \
        --region "${var.aws_region}"

      echo "Applying ArgoCD ingress..."
      kubectl apply -f "$BASE/install/argocd-ingress.yaml"

      echo "Applying ArgoCD project..."
      sed -e "s|REPO_URL|$REPO_URL|g" \
          "$BASE/projects/retail-store-project.yaml" | kubectl apply -f -

      echo "Applying dev applications (branch: $DEV_BRANCH)..."
      for f in "$BASE/applications/dev/"*.yaml; do
        sed -e "s|REPO_URL|$REPO_URL|g" \
            -e "s|REPO_BRANCH_DEV|$DEV_BRANCH|g" \
            "$f" | kubectl apply -f -
      done

      echo "Applying prod applications (branch: $PROD_BRANCH)..."
      for f in "$BASE/applications/prod/"*.yaml; do
        sed -e "s|REPO_URL|$REPO_URL|g" \
            -e "s|REPO_BRANCH_PROD|$PROD_BRANCH|g" \
            "$f" | kubectl apply -f -
      done

      echo "Applying prod-canary applications (branch: $PROD_BRANCH)..."
      for f in "$BASE/applications/prod-canary/"*.yaml; do
        sed -e "s|REPO_URL|$REPO_URL|g" \
            -e "s|REPO_BRANCH_PROD|$PROD_BRANCH|g" \
            "$f" | kubectl apply -f -
      done

      echo "Applying sonarqube application (branch: $PROD_BRANCH)..."
      sed -e "s|REPO_URL|$REPO_URL|g" \
          -e "s|REPO_BRANCH_PROD|$PROD_BRANCH|g" \
          "$BASE/applications/sonarqube.yaml" | kubectl apply -f -

      echo "ArgoCD applications deployed successfully!"
    EOT
  }

  triggers = {
    repo_url    = var.repo_url
    dev_branch  = var.dev_branch
    prod_branch = var.prod_branch
  }
}
