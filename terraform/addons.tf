# =============================================================================
# EKS ADD-ONS AND EXTENSIONS
# =============================================================================

module "eks_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  # Cluster information
  cluster_name      = module.retail_app_eks.cluster_name
  cluster_endpoint  = module.retail_app_eks.cluster_endpoint
  cluster_version   = module.retail_app_eks.cluster_version
  oidc_provider_arn = module.retail_app_eks.oidc_provider_arn

  # =============================================================================
  # CERT-MANAGER - disabled; TLS is terminated by ACM on the NLB
  # =============================================================================
  enable_cert_manager = false

  # =============================================================================
  # NGINX INGRESS CONTROLLER - Load Balancing and Routing
  # TLS terminates at the NLB using the ACM wildcard cert.
  # NGINX receives plain HTTP and routes by Host header.
  # =============================================================================
  enable_ingress_nginx = true
  ingress_nginx = {
    most_recent = true
    namespace   = "ingress-nginx"

    set = [
      {
        name  = "controller.service.type"
        value = "LoadBalancer"
      },
      {
        name  = "controller.service.externalTrafficPolicy"
        value = "Local"
      },
      # Trust X-Forwarded-Proto from NLB so HTTPS redirects work correctly
      {
        name  = "controller.config.use-forwarded-headers"
        value = "true"
      },
      {
        name  = "controller.config.forwarded-for-header"
        value = "X-Forwarded-For"
      },
      {
        name  = "controller.resources.requests.cpu"
        value = "100m"
      },
      {
        name  = "controller.resources.requests.memory"
        value = "128Mi"
      },
      {
        name  = "controller.resources.limits.cpu"
        value = "200m"
      },
      {
        name  = "controller.resources.limits.memory"
        value = "256Mi"
      }
    ]

    set_sensitive = [
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
        value = "internet-facing"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
        value = "nlb"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
        value = "instance"
      },
      # Attach ACM wildcard cert to NLB for TLS termination
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-cert"
        value = aws_acm_certificate_validation.wildcard.certificate_arn
      },
      # NLB terminates 443 with ACM; forwards plain HTTP to NGINX
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-ports"
        value = "443"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-backend-protocol"
        value = "http"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-health-check-path"
        value = "/healthz"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-health-check-port"
        value = "10254"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-health-check-protocol"
        value = "HTTP"
      }
    ]
  }

  # =============================================================================
  # OPTIONAL: MONITORING STACK
  # =============================================================================
  # Uncomment below to enable monitoring (increases costs)
  
  # enable_kube_prometheus_stack = var.enable_monitoring
  # kube_prometheus_stack = {
  #   most_recent = true
  #   namespace   = "monitoring"
  # }

  # =============================================================================
  # OPTIONAL: AWS LOAD BALANCER CONTROLLER
  # =============================================================================
  # enable_aws_load_balancer_controller = true
  # aws_load_balancer_controller = {
  #   most_recent = true
  #   namespace   = "kube-system"
  # }

  depends_on = [module.retail_app_eks]
}
