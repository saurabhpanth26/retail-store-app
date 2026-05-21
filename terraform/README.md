# Terraform — Retail Store Infrastructure

Provisions the complete AWS infrastructure for the retail store application:
VPC → EKS → NGINX Ingress (NLB + ACM TLS) → ArgoCD → Route53 DNS.

---

## File Structure

```
terraform/
├── main.tf              # VPC + EKS cluster (Auto Mode)
├── addons.tf            # EKS add-ons: NGINX Ingress (NLB, ACM cert attached)
├── acm.tf               # ACM wildcard cert + Route53 hosted zone + A records
├── argocd.tf            # ArgoCD Helm install + application deployment
├── monitoring.tf        # Monitoring stack: Prometheus, Loki, Alloy, Grafana + IRSA
├── s3-log-buckets.tf    # Dev + Prod S3 log buckets (Loki chunk storage)
├── security.tf          # Security groups
├── locals.tf            # AZ / subnet / tag locals + data sources
├── variables.tf         # Input variables
├── outputs.tf           # Cluster name, ACM ARN, nameservers, endpoints, bucket names
├── versions.tf          # Provider versions + S3 backend declaration
├── backend.hcl          # S3 backend config (bucket, key, region)
└── README.md
```

---

## Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| Terraform | **>= 1.10** | https://developer.hashicorp.com/terraform/install |
| AWS CLI | >= 2.x | https://aws.amazon.com/cli/ |
| kubectl | any recent | https://kubernetes.io/docs/tasks/tools/ |
| helm | >= 3.x | https://helm.sh/docs/intro/install/ |

AWS credentials must be configured before running any command:

```bash
aws configure
# or
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-west-2
```

---

## Step 0 — Bootstrap the S3 Backend (Run Once)

Terraform stores state remotely in S3.  
The bucket and lock file (native Terraform >= 1.10, no DynamoDB needed)
must exist before `terraform init` can connect to the backend.

```bash
# From the repo root
chmod +x scripts/setup-tf-backend.sh
./scripts/setup-tf-backend.sh
```

The script creates:

| Resource | Name | Purpose |
|---|---|---|
| S3 Bucket | `retail-store-tfstate-<account-id>-us-west-2` | Remote state storage |
| Bucket versioning | enabled | Recover from accidental state corruption |
| Bucket encryption | AES-256 | State file encryption at rest |
| Public access block | fully blocked | No accidental public exposure |

It also auto-updates `backend.hcl` with the resolved bucket name.

> If you want a different region, run:
> ```bash
> AWS_REGION=eu-west-1 ./scripts/setup-tf-backend.sh
> ```

---

## Step 1 — Init with Remote Backend

```bash
cd terraform

terraform init -backend-config=backend.hcl
```

Expected output:
```
Successfully configured the backend "s3"!
Terraform has been successfully initialized!
```

---

## Step 2a — Bootstrap the Cluster (targeted apply)

The Kubernetes and Helm providers in this project authenticate against the EKS
cluster endpoint. On a **fresh deploy the cluster does not exist yet**, so a
plain `terraform apply` would fail when Terraform tries to initialise those
providers.

Run a targeted apply first to create just the VPC and EKS cluster:

```bash
terraform apply \
  -target=random_string.suffix \
  -target=module.vpc \
  -target=module.retail_app_eks
```

> **Duration:** ~15 minutes — EKS cluster creation is the slowest step.

Once this completes the cluster is live and the providers can authenticate.

---

## Step 2b — Full Apply (everything else)

Now run a full apply. Terraform will deploy all remaining resources in
dependency order:

```bash
terraform apply
```

This provisions:
- S3 log buckets (dev + prod) with lifecycle policies
- IAM IRSA role for Loki S3 access
- NGINX Ingress Controller (NLB, internet-facing)
- ACM wildcard certificate (`*.saurabh-devops.in` + `saurabh-devops.in`)
- Route53 hosted zone + DNS validation CNAME records
- ArgoCD (Helm, `argocd` namespace)
- Monitoring stack — Prometheus → Loki → Grafana Alloy → Grafana (`monitoring` namespace)

> **Note:** Route53 A records (root + subdomains → NLB) are skipped on this
> apply because the NLB hostname is not yet known. They are created in Step 5.

---

## Step 3 — Point Your Domain to Route53

After Step 2 completes, get the Route53 nameservers:

```bash
terraform output route53_nameservers
```

Example output:
```
[
  "ns-123.awsdns-45.com",
  "ns-678.awsdns-90.net",
  "ns-111.awsdns-22.co.uk",
  "ns-333.awsdns-55.org"
]
```

Go to your domain registrar (GoDaddy / Namecheap / etc.) and replace the
existing NS records for `saurabh-devops.in` with these 4 nameservers.

> DNS propagation takes 5–30 minutes. ACM certificate validation happens
> automatically via Route53 once propagation completes.

Check ACM validation status:
```bash
terraform output acm_certificate_status
# Should return: ISSUED
```

---

## Step 4 — Configure kubectl

```bash
# Get the full cluster name (has a random 4-char suffix)
terraform output cluster_name

# Update kubeconfig
aws eks update-kubeconfig \
  --region us-west-2 \
  --name $(terraform output -raw cluster_name)

# Verify
kubectl get nodes
```

---

## Step 5 — Second Apply (Route53 A Records)

After the NLB is provisioned by NGINX Ingress (happens during Step 2),
run a second apply to create the DNS A records:

```bash
terraform apply
```

This creates Route53 A records pointing to the NLB for:

| Record | Target |
|---|---|
| `saurabh-devops.in` | NLB hostname |
| `dev.saurabh-devops.in` | NLB hostname |
| `argocd.saurabh-devops.in` | NLB hostname |
| `sonarqube.saurabh-devops.in` | NLB hostname |
| `grafana.saurabh-devops.in` | NLB hostname |

Verify the NLB is ready:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP column should show a hostname (not <pending>)
```

---

## Step 6 — Deploy ArgoCD Applications

Apply the ArgoCD project and applications to the cluster:

```bash
# Apply ArgoCD project (permissions)
kubectl apply -f ../argocd/projects/retail-store-project.yaml

# Apply ArgoCD ingress (argocd.saurabh-devops.in)
kubectl apply -f ../argocd/install/argocd-ingress.yaml

# Deploy dev applications
kubectl apply -f ../argocd/applications/dev/

# Deploy prod applications
kubectl apply -f ../argocd/applications/prod/

# Deploy prod canary applications
kubectl apply -f ../argocd/applications/prod-canary/

# Deploy SonarQube
kubectl apply -f ../argocd/applications/sonarqube.yaml
```

---

## Step 7 — Access ArgoCD

```bash
# Get the admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Open in browser
open https://argocd.saurabh-devops.in
# Username: admin
# Password: (from above)
```

---

## Application Endpoints (after full deploy)

| Application | URL |
|---|---|
| Prod store | `https://saurabh-devops.in` |
| Dev store | `https://dev.saurabh-devops.in` |
| ArgoCD | `https://argocd.saurabh-devops.in` |
| SonarQube | `https://sonarqube.saurabh-devops.in` (admin / admin) |
| Grafana | `https://grafana.saurabh-devops.in` (admin / `var.grafana_admin_password`) |

---

## Architecture

```
Internet (HTTPS:443)
        │
        ▼
 AWS NLB  ◄── ACM wildcard cert (*.saurabh-devops.in)
        │      TLS terminates HERE — no cert-manager needed
        │      Forwards plain HTTP + X-Forwarded-Proto: https
        ▼
 NGINX Ingress Controller
        │  Routes by Host header
        ├──► retail-store-prod ns  →  saurabh-devops.in
        ├──► retail-store-dev ns   →  dev.saurabh-devops.in
        ├──► argocd ns             →  argocd.saurabh-devops.in
        ├──► sonarqube ns          →  sonarqube.saurabh-devops.in
        └──► monitoring ns         →  grafana.saurabh-devops.in

 Route53 (saurabh-devops.in)
   A  saurabh-devops.in           → NLB
   A  dev.saurabh-devops.in       → NLB
   A  argocd.saurabh-devops.in    → NLB
   A  sonarqube.saurabh-devops.in → NLB
   A  grafana.saurabh-devops.in   → NLB
   CNAME  _acme-challenge.*       → ACM DNS validation

 EKS Cluster (Auto Mode, us-west-2)
   VPC: 10.0.0.0/16
   ├── Public subnets  (10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24)  ← NLB
   └── Private subnets (10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24) ← pods
```

---

## Variables Reference

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-west-2` | AWS region |
| `cluster_name` | `retail-store` | EKS cluster base name (random suffix appended) |
| `environment` | `dev` | Environment tag |
| `kubernetes_version` | `1.33` | EKS Kubernetes version |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `domain_name` | `saurabh-devops.in` | Root domain for ACM + Route53 |
| `enable_single_nat_gateway` | `true` | `false` = one NAT per AZ (higher cost, higher availability) |
| `enable_monitoring` | `true` | Kept for reference — monitoring always deploys via `monitoring.tf` |
| `grafana_admin_password` | `admin123` | Grafana admin password (sensitive — override in production) |
| `dev_log_retention_days` | `60` | Days before dev log objects expire in S3 |
| `prod_log_retention_days` | `365` | Days before prod log objects expire in S3 |

Override any variable at plan/apply time:
```bash
terraform apply -var="environment=prod" -var="enable_single_nat_gateway=false"
```

---

## Key Outputs

```bash
terraform output cluster_name            # Full cluster name with suffix
terraform output cluster_endpoint        # EKS API endpoint
terraform output configure_kubectl       # Ready-to-run kubeconfig command
terraform output acm_certificate_arn     # ACM cert ARN (used by NLB)
terraform output acm_certificate_status  # ISSUED / PENDING_VALIDATION
terraform output route53_nameservers     # NS records to set at your registrar
terraform output domain_endpoints        # All app URLs
terraform output aws_region              # Deployed AWS region
terraform output dev_logs_bucket_name    # S3 bucket name for dev Loki logs
terraform output prod_logs_bucket_name   # S3 bucket name for prod Loki logs
terraform output loki_irsa_role_arn      # IAM role used by Loki service account
terraform output grafana_get_url         # kubectl command to get the Grafana ALB URL
```

---

## Step 8 — Deploy the Monitoring Stack

The monitoring stack is fully managed by Terraform (`monitoring.tf`).
No separate scripts are needed — a single `terraform apply` deploys everything.

### What gets deployed

| Component | Helm chart | Version | Namespace | Purpose |
|---|---|---|---|---|
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | 67.4.0 | `monitoring` | Prometheus + Alertmanager + Node Exporter + kube-state-metrics |
| Loki | `grafana/loki` | 6.29.0 | `monitoring` | Log aggregation backend (SingleBinary, S3 storage) |
| Grafana Alloy | `grafana/alloy` | 0.12.0 | `monitoring` | DaemonSet — collects logs + metrics from `retail-store-dev` namespace |
| Grafana | `grafana/grafana` | 8.10.4 | `monitoring` | Dashboards UI — exposed via AWS ALB |

### S3 log buckets (created by Terraform)

| Bucket | Used when | Retention |
|---|---|---|
| `retail-store-dev-logs-<suffix>` | `var.environment != "prod"` | 60 d — STANDARD → IA at 30 d |
| `retail-store-prod-logs-<suffix>` | `var.environment == "prod"` | 365 d — STANDARD → IA at 30 d → Glacier at 90 d |

Loki's service account uses **IRSA** (IAM Role for Service Accounts) so no
static credentials are ever stored in the cluster.

### Deploy

The monitoring stack is included in the standard apply — it deploys
automatically alongside the cluster.

```bash
# Use the default Grafana password or override it:
terraform apply -var="grafana_admin_password=MyStr0ngPass!"

# For prod (routes Loki to the prod S3 bucket):
terraform apply -var="environment=prod" -var="grafana_admin_password=MyStr0ngPass!"
```

Terraform deploys in the correct dependency order:
`Prometheus → Loki → Grafana Alloy → Grafana`

### Verify

```bash
# All monitoring pods should be Running
kubectl get pods -n monitoring

# Get the Grafana ALB URL (ALB provisions in ~2-3 min after apply)
kubectl get ingress grafana -n monitoring

# Also available as a Terraform output:
terraform output grafana_get_url

# Confirm Alloy is shipping logs
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=20

# Confirm Loki is receiving log labels
kubectl run lokitest --image=busybox:1.28 --rm -it --restart=Never \
  -n monitoring -- wget -qO- "http://loki-gateway/loki/api/v1/labels"
```

### Grafana login

| Field | Value |
|---|---|
| URL | ALB hostname from `kubectl get ingress grafana -n monitoring` |
| Username | `admin` |
| Password | `var.grafana_admin_password` (default: `admin123` — override in production) |

Pre-built dashboards are provisioned automatically under the **Kubernetes** folder:

- Kubernetes Cluster Overview (ID 315)
- Kubernetes Pods (ID 13770)
- Node Exporter Full (ID 1860)
- Loki Logs (ID 13639)
- Kubernetes Namespace (ID 15758)
- Alertmanager (ID 9578)

### Monitoring architecture

```
retail-store-dev namespace pods
   │  logs (K8s API)            │  metrics (prometheus.io/scrape: "true")
   ▼                             ▼
 Grafana Alloy (DaemonSet)
   │                             │
   ▼                             ▼
 Loki gateway → Loki          Prometheus
 (chunks → S3 via IRSA)       (metrics → EBS PVC)
   │                             │
   └──────────────┬──────────────┘
                  ▼
               Grafana  ←── AWS ALB (internet-facing HTTP)

 Terraform-managed S3 buckets
 ├── retail-store-dev-logs-<suffix>   ← environment != "prod"
 └── retail-store-prod-logs-<suffix>  ← environment == "prod"
```

---

## Destroy

```bash
# Remove all AWS resources
terraform destroy
```

> This deletes the EKS cluster, VPC, NLB, ACM certificate, and Route53 zone.
> The S3 state bucket is NOT deleted by `terraform destroy` — remove it manually
> if no longer needed:
> ```bash
> aws s3 rb s3://retail-store-tfstate-<account-id>-us-west-2 --force
> ```
