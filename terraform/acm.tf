# =============================================================================
# ACM CERTIFICATE + ROUTE53 DNS
# =============================================================================

# Route53 public hosted zone for the domain
resource "aws_route53_zone" "main" {
  name = var.domain_name
  tags = local.common_tags
}

# Wildcard ACM certificate — covers all subdomains + root in one cert:
#   saurabh-devops.in
#   *.saurabh-devops.in  →  dev.saurabh-devops.in, argocd.saurabh-devops.in, etc.
resource "aws_acm_certificate" "wildcard" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-wildcard-cert"
  })
}

# Route53 DNS validation records (deduplicated — root + wildcard share the same CNAME)
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.main.zone_id
}

# Wait for ACM to confirm validation before outputs are usable
resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# =============================================================================
# ROUTE53 ALIAS RECORDS
# NLB hostname is only known after cluster + ingress-nginx is running.
# These records are created via a data source lookup on the NLB service.
# Run `terraform apply` a second time after the NLB is provisioned.
# =============================================================================

data "kubernetes_service" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [module.eks_addons]
}

locals {
  nlb_hostname = try(
    data.kubernetes_service.ingress_nginx.status[0].load_balancer[0].ingress[0].hostname,
    null
  )
}

# NLB hosted zone ID per region (required for Route53 alias records)
locals {
  nlb_zone_ids = {
    us-east-1    = "Z26RNL4JYFTOTI"
    us-east-2    = "ZLMOA37VPKANP"
    us-west-1    = "Z24FKFUX50B4VW"
    us-west-2    = "Z18D5FSROUN65G"
    eu-west-1    = "Z2IFOLAFXWLO4F"
    eu-west-2    = "ZD4D7Y8KGAS4G"
    eu-central-1 = "Z3F0SRJ5LGBH90"
    ap-southeast-1 = "Z19DQILCV0OWEC"
    ap-northeast-1 = "Z31USIVVIZKD4A"
    ap-south-1     = "ZVDDRBQ08TROA"
  }
  nlb_hosted_zone_id = lookup(local.nlb_zone_ids, var.aws_region, "")
}

# Root domain  →  NLB
resource "aws_route53_record" "root" {
  count   = local.nlb_hostname != null ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = local.nlb_hostname
    zone_id                = local.nlb_hosted_zone_id
    evaluate_target_health = true
  }
}

# dev subdomain  →  NLB
resource "aws_route53_record" "dev" {
  count   = local.nlb_hostname != null ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = "dev.${var.domain_name}"
  type    = "A"

  alias {
    name                   = local.nlb_hostname
    zone_id                = local.nlb_hosted_zone_id
    evaluate_target_health = true
  }
}

# argocd subdomain  →  NLB
resource "aws_route53_record" "argocd" {
  count   = local.nlb_hostname != null ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = "argocd.${var.domain_name}"
  type    = "A"

  alias {
    name                   = local.nlb_hostname
    zone_id                = local.nlb_hosted_zone_id
    evaluate_target_health = true
  }
}

# sonarqube subdomain  →  NLB
resource "aws_route53_record" "sonarqube" {
  count   = local.nlb_hostname != null ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = "sonarqube.${var.domain_name}"
  type    = "A"

  alias {
    name                   = local.nlb_hostname
    zone_id                = local.nlb_hosted_zone_id
    evaluate_target_health = true
  }
}
