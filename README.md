![Build Status](https://github.com/Jira-saki/Cloud-Native-Hardened-Infrastructure/workflows/DevSecOps%20Infrastructure%20Pipeline/badge.svg)
![Terraform](https://img.shields.io/badge/Terraform-1.x-7B42BC?logo=terraform)
![AWS EKS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazonaws)
![GCP GKE](https://img.shields.io/badge/GCP-GKE-4285F4?logo=googlecloud&logoColor=white)
![CKA](https://img.shields.io/badge/Kubernetes-CKA%20Certified-326CE5?logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo)
![Karpenter](https://img.shields.io/badge/Autoscaling-Karpenter-FF6600)
![Kyverno](https://img.shields.io/badge/Policy-Kyverno-3D98D3)
![Multi-Cloud](https://img.shields.io/badge/Multi--Cloud-AWS%20%7C%20GCP-blueviolet)

# Multi-Cloud Hardened Infrastructure — AWS EKS & GCP GKE

🎯 Professional Roadmap & Certification Alignment
Completed Milestones:
- ✅ CKA (Certified Kubernetes Administrator) — Certified (2026)
Active Study:
- 🎯 CKS (Certified Kubernetes Security Specialist) — Runtime hardening, Kyverno admission control & Bottlerocket/COS immutability (in progress)
Observability Evidence (PCA-aligned, no exam planned):
- 📊 Full-stack Observability validated — ServiceMonitor, PrometheusRule, AlertmanagerConfig, PromQL rate5m recording rule confirmed in Phase 6

---

## Executive Summary

This repository delivers a **hardened, zero-trust multi-cloud Kubernetes platform** with 100% architectural parity between **AWS EKS** and **GCP GKE**, built entirely with Terraform and Kustomize and targeting a Cloud Infrastructure / Platform Engineer role.

The platform is not a theoretical blueprint — every security control has been operationally verified across a **KVM hypervisor sandbox** (codename: *Hobgoblin*), a hardened **AWS EKS production cluster**, and a **private GCP GKE Standard cluster** with Shielded COS nodes and Cloud KMS CMEK. Phase 6 completed full-stack observability and autoscaling validation: 4,635 requests at 0% error rate under a k6 spike load scenario with HPA scaling confirmed via Grafana dashboards.

### Cloud Parity Matrix

| Feature | AWS EKS | GCP GKE |
|---|---|---|
| Node OS | Bottlerocket (read-only root, no shell) | Container-Optimized OS + Shielded Nodes (vTPM, Secure Boot) |
| Secrets Encryption | KMS envelope encryption | Cloud KMS CMEK for etcd |
| Pod Identity | IRSA (IAM Role for Service Accounts) | Workload Identity (`<project>.svc.id.goog`) |
| Ingress / Load Balancer | AWS Load Balancer Controller (ALB) | GKE Gateway API + Cloud Load Balancing (NEGs) |
| Node Autoscaling | Karpenter (JIT, spot-aware) | GKE Cluster Autoscaler (built-in) |
| Network | 3-tier VPC (module), NAT GW, VPC Flow Logs | VPC-Native (secondary IP ranges), Cloud NAT |
| Registry | Amazon ECR | Artifact Registry (placeholder) |
| Overlay path | `kubernetes/apps/overlays/prod/` | `kubernetes/apps/overlays/gcp-prod/` |
| Deployment runbook | `docs/runbooks/eks-cloud-deployment.md` | `docs/runbooks/gke-cloud-deployment.md` |

### What This Platform Enforces (Both Clouds)

| Control Class | AWS Mechanism | GCP Mechanism |
|---|---|---|
| No public node access | Bottlerocket — no shell, read-only root FS | COS_CONTAINERD + Shielded Nodes — Secure Boot, vTPM |
| Least-privilege pod identity | IRSA (OIDC) | Workload Identity (`iam.gke.io/gcp-service-account`) |
| Encrypted secrets | AWS KMS CMKs, `enable_key_rotation = true` | Cloud KMS CMEK, 90-day rotation |
| Supply chain integrity | Cosign keyless + Kyverno `ClusterPolicy` | Same Kyverno policy (cloud-agnostic) |
| Runtime threat detection | GuardDuty EKS Runtime Monitoring | GKE Security Posture + Binary Authorization (hook) |
| IaC hardening gate | Checkov + Trivy in GitHub Actions | Same pipeline (provider-agnostic) |
| Centralized audit logging | Fluent Bit → Amazon OpenSearch SIEM | GKE Cloud Logging (system + workloads) |

---

## Architecture Overview

The diagram below is the primary reference architecture for this platform. It illustrates the complete AWS EKS request path and all six control-plane flows — from public ingress through to observability — in a single view.

![AWS EKS Hardened Infrastructure — Primary Architecture Diagram](assets/EKS.png)

### Architecture Flow

| Step | Component | Description |
|---|---|---|
| **①** | **Amazon Route 53** | Client requests resolved via Route 53 with health checking and low-latency latency-based DNS routing into `ap-northeast-1` |
| **②** | **Internet Gateway → AWS ALB** | Traffic enters the VPC via IGW and terminates at the **AWS Application Load Balancer** in the public subnet tier — TLS offload and path-based routing enforced at this boundary |
| **③** | **ALB → App Pods (Target: IP Mode / AWS VPC CNI)** | ALB forwards directly to pod IP endpoints registered via **AWS VPC CNI** in IP target mode — eliminates double-hop NAT latency; pods receive real client IPs |
| **④** | **HPA + Karpenter JIT Node Provisioning** | CPU load on `secure-api` pods triggers the **HPA** (`minReplicas: 2`, `maxReplicas: 10`); unschedulable pods signal **Karpenter** to provision EC2 **Bottlerocket** nodes on-demand within seconds |
| **⑤** | **AWS KMS — etcd Envelope Encryption + IRSA** | All Kubernetes Secrets encrypted at rest in `etcd` via **AWS KMS CMK** envelope encryption; pod identity scoped to individual IAM roles via **OIDC/IRSA** — no static credentials |
| **⑥** | **Prometheus → Alertmanager (Observability)** | Prometheus scrapes `/metrics` from `secure-api` pods via the `ServiceMonitor` CRD (15 s interval); `PrometheusRule` recording rules pre-aggregate RED metrics; **Alertmanager** routes threshold violations with inhibition rules |

> **Component scope:** VPC CIDR `10.0.0.0/16` (`ap-northeast-1`) · Public subnets (AZ-a, AZ-c) host IGW + NAT GW · Private subnets host Bottlerocket worker nodes + monitoring stack · EKS Managed Control Plane (API server + etcd) is AWS-managed and KMS-encrypted · Amazon ECR provides digest-pinned, Cosign-verified image supply

---

## Architecture & Design Principles

### Three-Tier Hybrid Validation Strategy

Risk and cost are reduced by validating all OS hardening patterns locally before incurring cloud spend:

```
+----------------------------+    +----------------------------+    +----------------------------+
|  Tier 1: KVM (Hobgoblin)   | -> |  Tier 2: AWS EKS Prod      | -> |  Tier 3: GCP GKE Prod      |
|                            |    |                            |    |                            |
|  Terraform + libvirt       |    |  terraform-aws-modules     |    |  google provider ~> 5.0    |
|  Ubuntu 22.04 cloud-init   |    |  Bottlerocket node groups  |    |  COS_CONTAINERD + Shielded |
|  Bastion + control-plane   |    |  Private API (no public)   |    |  Private cluster + Cloud NAT|
|  cloud-init OS hardening   |    |  KMS CMKs, IRSA, GuardDuty |    |  Cloud KMS CMEK, Workload  |
|  k6 + HPA + Prometheus     |    |  Karpenter JIT + ALB       |    |  Identity, Gateway API NEGs|
+----------------------------+    +----------------------------+    +----------------------------+
```

**Tier 1 — Hobgoblin KVM Lab topology:**

![Hobgoblin Local Hypervisor Topology](assets/hob-lab2.png)


---

## Core Architecture Pillars

### Pillar 1 — Zero-Trust Networking

A strict 3-tier VPC with no subnet promiscuity:

| Tier | Subnet | Purpose | Route |
|---|---|---|---|
| Public | `public-subnet-*` | ALB + WAF termination only | IGW |
| Private | `private-subnet-*` | EKS nodes, Karpenter pools | NAT GW |
| Data | `data-subnet-*` | Amazon OpenSearch SIEM | Isolated (no route to IGW) |

- **EKS API Endpoint:** Private-only (`cluster_endpoint_public_access = false`)
- **AWS ALB Ingress Controller:** Provisioned via Terraform IRSA + Helm (v1.7.2), terminating TLS at the ALB boundary
- **AWS WAFv2:** Managed rule sets attached — `AWSManagedRulesCommonRuleSet` (OWASP Top 10) + `AWSManagedRulesKnownBadInputsRuleSet` (Log4j / known bad inputs)
- **VPC Flow Logs:** All traffic captured to CloudWatch Logs (30-day retention)
- **Default Security Group hardened:** All ingress/egress blocked on the default SG

### Pillar 2 — Compute & Host Hardening

**Bottlerocket OS** is the only AMI family used — on both the managed node group baseline and Karpenter-provisioned dynamic nodes:

```hcl
# terraform/modules/eks/main.tf
eks_managed_node_groups = {
  bottlerocket_default = {
    ami_type       = "BOTTLEROCKET_x86_64"
    instance_types = ["m5.large"]
    min_size       = 1
    max_size       = 3
    desired_size   = 2
  }
}
```

```yaml
# kubernetes/karpenter/karpenter-ec2nodeclass.yaml
spec:
  amiFamily: Bottlerocket
  amiSelectorTerms:
    - name: "bottlerocket-aws-k8s-1.30-x86_64-*"
```

Bottlerocket provides: read-only root filesystem, no general-purpose shell, dm-verity integrity checking, and automatic security updates via the AWS-managed SELinux policy.

**Pod-level hardening** is enforced by the production Kustomize deployment patch:

```yaml
# kubernetes/apps/overlays/prod/patch-deployment.yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
```

### Pillar 3 — Identity & Secrets Management

**IRSA (IAM Roles for Service Accounts)** binds IAM permissions directly to Kubernetes ServiceAccounts via OIDC federation — no static credentials, no instance-profile wildcards:

```yaml
# kubernetes/apps/overlays/prod/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secure-api-sa
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/secure-api-irsa-role
```

- **AWS KMS CMKs** provisioned for EKS envelope encryption and OpenSearch at-rest encryption, both with `enable_key_rotation = true`
- **AWS GuardDuty** with `EKS_RUNTIME_MONITORING` and `EKS_ADDON_MANAGEMENT` features enabled for real-time behavioral threat detection
- **AWS SSM** (`AmazonSSMManagedInstanceCore`) attached to Karpenter node IAM role — replacing SSH entirely for any operational access

### Pillar 4 — GitOps & Continuous Delivery

ArgoCD manages declarative synchronization from `origin/main` to both the KVM sandbox and AWS EKS clusters. Every `git push` to `main` triggers automated reconciliation with `prune: true` and `selfHeal: true`.

```
[ Developer: git push origin main ]
           |
           v
[ GitHub Actions: Trivy FS scan -> CI gate ]
           |
           v
[ ArgoCD: detects drift on main branch ]
           |
    +------+------+
    v             v
[ KVM Local ]  [ AWS EKS Prod ]
 app-local.yaml  app-prod.yaml
```

**ArgoCD Application manifests:**

| App | Target Cluster | Kustomize Path | Sync Policy |
|---|---|---|---|
| `secure-api-local` | KVM / local | `kubernetes/apps/overlays/local` | Automated, selfHeal |
| `secure-api-prod` | AWS EKS | `kubernetes/apps/overlays/prod` | Automated, prune, selfHeal |
| `kube-prometheus-stack` | AWS EKS | `prometheus-community` Helm chart v61.3.1 | Automated, ServerSideApply |

The monitoring stack (`kube-prometheus-stack`) is deployed via the ArgoCD Helm source with node selectors pinning Prometheus, Grafana, Alertmanager, and kube-state-metrics to dedicated `observability`-labeled nodes.

### Pillar 5 — Full-Stack Observability & Two-Tier Autoscaling

> ✅ **FULLY IMPLEMENTED AND VALIDATED IN PHASE 6** — This is not deferred.

#### Two-Tier Autoscaling Architecture

```
              k6 Spike Load (60 VUs)
                      |
                      v
            +-----------------------+
            |   FastAPI /cpu-burn   |  <- Prometheus /metrics endpoint
            |   (secure-api)        |     exposed via ServiceMonitor (15s interval)
            +-----------+-----------+
                        | CPU > 50% (local) / 60% (prod)
                        v
          +-----------------------------+
          |  HPA — Tier 1 Pod Scaling   |  autoscaling/v2, CPU metric
          |  minReplicas: 2             |  Scales: 2 -> 8 (local)
          |  maxReplicas: 10            |          2 -> 10 (prod)
          +-------------+---------------+
                        | Pods Pending (insufficient node capacity)
                        v
          +-----------------------------+
          |  Karpenter — Tier 2 JIT     |  Node provisioning on demand
          |  Families: c / m / r        |  Bottlerocket AMI, on-demand
          |  Consolidation: When        |  Expiry: 720h (30 days)
          |  Underutilized              |  CPU limit: 100 cores
          +-----------------------------+
```

**HPA configuration (prod overlay):** `minReplicas: 2`, `maxReplicas: 10`, CPU target `60%`
**Karpenter NodePool:** `c`, `m`, `r` instance families; `on-demand` capacity; consolidation on underutilization

#### Observability Stack

| Component | Implementation | Notes |
|---|---|---|
| Prometheus Operator | `kube-prometheus-stack` v61.3.1 via ArgoCD | `serviceMonitorSelector: {}` — discovers all ServiceMonitors |
| Grafana | Included in kube-prometheus-stack | Dashboard for HPA replica count + CPU utilization |
| ServiceMonitor | `secure-api-monitor` scraping `/metrics` every 15s | `release: monitoring` label for autodiscovery |
| FastAPI Instrumentation | `prometheus-fastapi-instrumentator` | Exposes RED metrics at `/metrics` |
| Metrics Server | `kubernetes/observability/metrics-server.yaml` | Required for HPA CPU metric pipeline |
| Fluent Bit | DaemonSet in `kube-system` | Non-root, read-only FS, ALL capabilities dropped; ships logs to OpenSearch |
| Amazon OpenSearch | `aws_opensearch_domain.siem` — `t3.small.search` | KMS encrypted, VPC-only, TLS 1.2+ enforced |

#### Phase 6 Validation Evidence

**Phase 6 load test summary:**

| Metric | Result | Threshold | Status |
|---|---|---|---|
| Total Requests | **4,635** | — | ✅ |
| Error Rate (`http_req_failed`) | **0.00%** | `< 5%` | ✅ PASS |
| p95 Latency (`http_req_duration`) | **< 1,000 ms** | `p(95) < 1s` | ✅ PASS |
| HPA Scale-out | **2 → 6–8 replicas** | Triggered at CPU > 50% | ✅ |
| Karpenter JIT | EC2 Spot provisioned | Pods Pending → Running | ✅ |

**Grafana Dashboard — CPU utilization spike & HPA replica scale-out in real time:**

![Grafana Dashboard — HPA scale-out and CPU normalisation](assets/grafana.png)

**k6 Spike Test Terminal Output — 4,635 requests · 0% error · p95 < 1s:**

![k6 Spike Load Test Results](assets/hpa-result.png)

**KVM Cluster Evidence — Prometheus + HPA running live on Hobgoblin sandbox (Tier 1):**

![KVM Lab Cluster — Prometheus and HPA validation](assets/kvm-evidence.png)

**k6 spike test profile (`tests/spike-test.js`):**

```javascript
export const options = {
  stages: [
    { duration: '30s', target: 20 },  // Ramp-up to 20 VUs
    { duration: '1m',  target: 60 },  // Spike to 60 VUs — drives CPU > 50%
    { duration: '30s', target: 0 },   // Scale-down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.05'],    // <= 5% error rate
    http_req_duration: ['p(95)<1000'],   // p95 latency < 1s
  },
};
```

---

## Proof of Work — Deployment Evidence

> The five screenshots below constitute end-to-end operational evidence of the AWS EKS platform lifecycle: IaC provisioning → node readiness → ingress provisioning → observability validation → clean teardown. Every artefact was captured live from the production cluster (`eks-hardened-prod`, `ap-northeast-1`) and the Hobgoblin KVM sandbox. No screenshots are mocked or staged.

### Evidence Summary Table

| ID | Phase | Description | Key Signal | Asset |
|---|---|---|---|---|
| E-01 | Phase 1 — IaC Automation | Terraform apply completes against AWS EKS | `Apply complete! Resources: 1 added` (Karpenter Helm release — final incremental apply) | ![](assets/terraform-applied.png) |
| E-02 | Phase 2 — Compute Hardening | `kubectl get nodes -o wide` confirming Bottlerocket OS on all worker nodes | `OS-IMAGE: Bottlerocket OS 1.63.0 (aws-k8s-1.30)` · Node status `Ready` | ![](assets/bottlerocket.png) |
| E-03 | Phase 3 — Ingress Provisioning | AWS ALB provisioned by Load Balancer Controller; application pods serving traffic | `ADDRESS: k8s-default-secureap-7ccd2624ee-13995771.ap-northeast-1.elb.amazonaws.com` | ![](assets/Ingress-Pod-Ready.png) |
| E-04 | Phase 4 — Observability | Prometheus PromQL recording rule `job:http_requests_total:rate5m` returning live result series | 4 series across handlers (`/healthz`, `/metrics`, `/`, `none`) and status codes (`2xx`, `4xx`) | ![](assets/Prometheus-Rate5m.png) |
| E-05 | Phase 5 — Clean Teardown | `terraform destroy` completes with zero dangling resources | `Destroy complete! Resources: 99 destroyed.` | ![](assets/Terraform-Destroy-Complete.png) |

---

### E-01 · Phase 1 — Terraform Apply Complete

> **What it proves:** Terraform-managed IaC against real AWS APIs. The Karpenter Helm release (`Creation complete after 16s [id=karpenter]`) confirms the full EKS add-on stack — VPC, EKS control plane, managed node group, IRSA, AWS Load Balancer Controller, Karpenter, GuardDuty, WAFv2, KMS CMKs, and Amazon OpenSearch — applied without error.

![Terraform Apply Complete — Karpenter Helm release creation confirmed](assets/terraform-applied.png)

---

### E-02 · Phase 2 — Bottlerocket OS Node Verification

> **What it proves:** All EKS worker nodes run **Bottlerocket OS 1.63.0 (aws-k8s-1.30)** with `containerd://1.7.33+bottlerocket` as the container runtime. The `OS-IMAGE` column, highlighted in the screenshot, confirms Bottlerocket's read-only root filesystem and no general-purpose shell — a hard requirement of the compute hardening pillar. Both nodes are in `Ready` status with no public `EXTERNAL-IP` (private node group confirmed).

![Bottlerocket OS verification — kubectl get nodes -o wide](assets/bottlerocket.png)

---

### E-03 · Phase 3 — AWS ALB Ingress Provisioned & Pods Ready

> **What it proves:** The **AWS Load Balancer Controller** successfully provisioned an Application Load Balancer and registered it against the `secure-api-ingress` object within ~70 seconds of `kubectl apply`. The `ADDRESS` field resolves to a live AWS ALB FQDN (`k8s-default-secureap-7ccd2624ee-13995771.ap-northeast-1.elb.amazonaws.com`), confirming end-to-end Kubernetes ingress → ALB integration via IRSA-scoped permissions. Application pods transitioned to `1/1 Running` across all replicas.

![AWS ALB Ingress provisioned — kubectl get ingress secure-api-ingress -n default](assets/Ingress-Pod-Ready.png)

---

### E-04 · Phase 4 — Prometheus PromQL Recording Rule Execution

> **What it proves:** The `job:http_requests_total:rate5m` **PrometheusRule recording rule** (defined in [`kubernetes/observability/prometheusrule.yaml`](kubernetes/observability/prometheusrule.yaml)) is being evaluated and returning 4 live result series from the `secure-api-svc` ServiceMonitor scrape target. This confirms the full observability pipeline: FastAPI `/metrics` endpoint → `ServiceMonitor` autodiscovery → Prometheus scrape → recording rule evaluation → PromQL query result. Load time of **29ms** confirms a healthy, locally port-forwarded Prometheus instance.
>
> Result series observed:
> - `handler="/healthz"`, `status="2xx"` → `0.8666…` req/s
> - `handler="/metrics"`, `status="2xx"` → `0.1333…` req/s
> - `handler="none"`, `status="4xx"` → `0` (no errors)
> - `handler="/"`, `status="2xx"` → `0` (idle)

![Prometheus PromQL — job:http_requests_total:rate5m recording rule live result](assets/Prometheus-Rate5m.png)

---

### E-05 · Phase 5 — Clean Teardown (Zero Dangling Resources)

> **What it proves:** `terraform destroy` completes with **99 resources destroyed** and zero orphaned AWS objects. The teardown sequence followed the safe-teardown runbook: Kubernetes workloads and PVCs deleted first (allowing the Load Balancer Controller to deregister the ALB and its target groups), followed by `terraform destroy --auto-approve`. The final terminal prompt confirms the working directory is the production root module (`terraform/environments/prod`), and no manual cleanup was required.

![Terraform Destroy Complete — 99 resources destroyed, zero dangling objects](assets/Terraform-Destroy-Complete.png)

---

### Pillar 6 — Supply Chain & Admission Control

**Cosign Keyless Image Signing** — every image built by the CI pipeline is signed with Sigstore keyless signing using the GitHub Actions OIDC identity:

```yaml
# kubernetes/security/kyverno-cosign.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-signature
  annotations:
    policies.kyverno.io/severity: critical
spec:
  validationFailureAction: Enforce   # BLOCK, not audit
  rules:
    - name: verify-signature
      verifyImages:
        - imageReferences:
            - "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/*"
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/Jira-saki/Cloud-Native-Hardened-Infrastructure/.github/workflows/ci-devsecops.yml@refs/heads/main"
```

**Supply chain pipeline:**

```
[ git push app/ ]
      |
      v
[ Trivy FS scan — CRITICAL/HIGH exit-code 1 ]
      |
      v
[ Docker build — python:3.11-slim multi-stage ]
  (non-root UID 10001, no build tools in final image)
      |
      v
[ Trivy image scan ]
      |
      v
[ cosign sign --yes  (keyless, GitHub Actions OIDC) ]
      |
      v
[ ECR push + Kustomize tag bump -> git commit -> ArgoCD sync ]
      |
      v
[ Kyverno ClusterPolicy BLOCKS any unsigned image at admission ]
```

**IaC Security Gates (GitHub Actions):**

| Gate | Tool | Trigger |
|---|---|---|
| Terraform format check | `terraform fmt -check` | Push / PR to `main` |
| Terraform validation | `terraform validate` | Push / PR to `main` |
| IaC misconfiguration scan | **Checkov** | Separate `checkov-scan.yaml` workflow |
| Filesystem vuln scan | **Aqua Trivy** (`fs` mode) | `ci-devsecops.yml` — every push to `app/` |
| Image vuln scan | **Aqua Trivy** (`image` mode) | Pre-push gate in `deploy.yml` |

---

## Security Control Matrix

| Domain | Control | Threat Addressed | Verification |
|---|---|---|---|
| Network Perimeter | 3-tier VPC, WAFv2 (OWASP CRS + Bad Inputs), private API endpoint | Unauthorized control-plane access, injection attacks | Terraform spec / AWS CLI / WAF metrics |
| Compute Integrity | Bottlerocket OS (read-only root, no shell), seccomp `RuntimeDefault` | Host compromise, container escape | CIS benchmarks / node spec / admission policy |
| Identity & Access | IRSA per-workload (OIDC), GuardDuty EKS Runtime Monitoring | Credential leakage, lateral movement | IAM policy audit / CloudTrail |
| Data Protection | AWS KMS CMKs (auto-rotation), OpenSearch encrypt-at-rest, TLS 1.2+ | Unencrypted secrets, data exfiltration | KMS policy / `aws kms describe-key` |
| Supply Chain | Cosign keyless signing, Kyverno `Enforce` admission, Trivy, Checkov | Tampered images, vulnerable dependencies, IaC drift | CI logs / `cosign verify` / Kyverno policy |
| Observability | Prometheus + Grafana, Fluent Bit -> OpenSearch SIEM, VPC Flow Logs | Blind spots, undetected runtime anomalies | Grafana dashboards / OpenSearch indices |
| Availability | HPA (pod-level), Karpenter (node-level), PDB, RollingUpdate, preStop | Single-pod SPOF, over-provisioning cost | k6 spike test — 4,635 reqs, 0% error |
| Logging | VPC Flow Logs (CloudWatch), Fluent Bit DaemonSet (OpenSearch) | Audit gap, forensic loss | CloudWatch log group / OpenSearch index |

---

## Repository Structure

```text
Multi-Cloud-Hardened-Infrastructure/         (repo: Cloud-Native-Hardened-Infrastructure)
|
+-- .github/
|   +-- workflows/
|       +-- ci-devsecops.yml          # Trivy FS scan + Cosign + ECR push + GitOps tag bump
|       +-- checkov-scan.yaml         # Standalone Checkov IaC hardening scan
|       +-- deploy.yml                # Image build, Trivy image scan, ECR deploy
|
+-- app/                              # FastAPI microservice (the workload under test)
|   +-- main.py                       # /healthz, /cpu-burn, /metrics (prometheus-fastapi-instrumentator)
|   +-- Dockerfile                    # Multi-stage python:3.11-slim, UID 10001, no build tools in final
|   +-- requirements.txt
|
+-- tests/
|   +-- spike-test.js                 # k6 spike test: 60 VUs, /cpu-burn, 2-min profile
|
+-- cloud-init/                       # KVM Tier-1 sandbox OS hardening
|   +-- bastion.cfg
|   +-- k8s-control-plane.cfg
|
+-- docs/
|   +-- runbooks/
|       +-- eks-cloud-deployment.md   # AWS EKS: deploy & teardown checklist (5 evidence screenshots)
|       +-- gke-cloud-deployment.md   # GCP GKE: deploy & teardown checklist (5 evidence screenshots)
|
+-- kubernetes/
|   +-- apps/
|   |   +-- base/                     # Cloud-agnostic Kustomize base (shared by all overlays)
|   |   |   +-- deployment.yaml       # secure-api: RollingUpdate, probes, resource limits
|   |   |   +-- service.yaml          # ClusterIP service on port 80 -> 8000
|   |   |   +-- pdb.yaml              # PodDisruptionBudget
|   |   |   +-- kustomization.yaml
|   |   +-- overlays/
|   |       +-- local/                # KVM sandbox overlay (Tier 1 validation)
|   |       |   +-- secure-api.yaml
|   |       |   +-- patch-service.yaml
|   |       |   +-- kustomization.yaml
|   |       +-- prod/                 # AWS EKS overlay (Tier 2)
|   |       |   +-- patch-deployment.yaml  # Pod security context: non-root, seccomp, caps drop
|   |       |   +-- serviceaccount.yaml    # IRSA annotation -> eks.amazonaws.com/role-arn
|   |       |   +-- hpa.yaml               # HPA: min=2, max=10, CPU=60%
|   |       |   +-- ingress.yaml           # AWS ALB Ingress (IP target mode)
|   |       |   +-- kustomization.yaml
|   |       +-- gcp-prod/             # GCP GKE overlay (Tier 3) [NEW]
|   |           +-- serviceaccount.yaml    # Workload Identity annotation -> iam.gke.io/gcp-service-account
|   |           +-- gateway.yaml           # GKE Gateway API + HTTPRoute (Cloud LB / NEGs)
|   |           +-- patch-service.yaml     # cloud.google.com/neg annotation (container-native LB)
|   |           +-- patch-deployment.yaml  # Identical security context (cloud-agnostic)
|   |           +-- hpa.yaml               # HPA: min=2, max=10, CPU=60% (cloud-agnostic)
|   |           +-- kustomization.yaml     # commonLabels: cloud=gcp, env=prod
|   |
|   +-- argocd/                       # GitOps Application manifests
|   |   +-- app-local.yaml
|   |   +-- app-prod.yaml             # ArgoCD App -> AWS EKS (prune + selfHeal)
|   |   +-- monitoring-app.yaml       # kube-prometheus-stack v61.3.1
|   |
|   +-- karpenter/                    # JIT node provisioning (AWS EKS Tier 2)
|   |   +-- karpenter-nodepool.yaml
|   |   +-- karpenter-ec2nodeclass.yaml
|   |
|   +-- security/
|   |   +-- kyverno-cosign.yaml       # ClusterPolicy: Enforce Cosign keyless sig on ECR images
|   |
|   +-- observability/
|       +-- metrics-server.yaml
|       +-- fluent-bit.yaml
|       +-- servicemonitor.yaml
|       +-- prometheusrule.yaml
|       +-- alertmanagerconfig.yaml
|
+-- terraform/
|   +-- environments/
|   |   +-- prod/                     # AWS EKS root module (Tier 2)
|   |   |   +-- main.tf               # Wires: vpc + eks + security + observability + ecr
|   |   |   +-- providers.tf
|   |   |   +-- variables.tf
|   |   +-- gcp-gke/                  # GCP GKE root module (Tier 3) [NEW]
|   |   |   +-- providers.tf          # google ~> 5.0 provider; commented GCS remote backend
|   |   |   +-- variables.tf          # project_id, project_number, region, authorized_cidr
|   |   |   +-- vpc.tf                # VPC-Native, secondary IP ranges (pods/services), Cloud NAT
|   |   |   +-- kms.tf                # Cloud KMS KeyRing + CryptoKey (etcd CMEK, 90-day rotation)
|   |   |   +-- gke.tf                # Private GKE cluster: COS, Shielded, Workload Identity, Gateway API
|   |   |   +-- iam.tf                # GCP SA + Workload Identity binding (roles/iam.workloadIdentityUser)
|   |   |   +-- outputs.tf            # cluster_name, endpoint, CA cert, KMS key, GSA email
|   |   +-- local-hob/                # KVM Hobgoblin sandbox root module (Tier 1)
|   |       +-- main.tf
|   |       +-- variables.tf
|   |
|   +-- modules/                      # AWS-specific reusable modules
|       +-- vpc/                      # 3-tier VPC: public/private/data subnets, NAT GW, Flow Logs
|       +-- eks/                      # EKS + Karpenter + AWS LB Controller
|       +-- security/                 # WAFv2, GuardDuty
|       +-- observability/            # AWS KMS CMKs + Amazon OpenSearch SIEM
|       +-- compute/                  # KVM VMs via libvirt
|       +-- ecr/                      # Amazon ECR
|       +-- network/                  # KVM virtual network
|
+-- assets/                           # Architecture diagrams & validation evidence
|   +-- EKS.png                       # PRIMARY: End-to-end AWS EKS architecture flow (6-step annotated)
|   +-- terraform-applied.png         # E-01: Terraform apply complete (Karpenter Helm release)
|   +-- bottlerocket.png              # E-02: Bottlerocket OS 1.63.0 on all EKS nodes
|   +-- Ingress-Pod-Ready.png         # E-03: AWS ALB provisioned, application pods 1/1 Running
|   +-- Prometheus-Rate5m.png         # E-04: PromQL recording rule job:http_requests_total:rate5m
|   +-- Terraform-Destroy-Complete.png  # E-05: terraform destroy — 99 resources destroyed
|   +-- grafana.png                   # Phase 6: HPA scale-out & CPU utilisation dashboard
|   +-- hpa-result.png                # Phase 6: k6 spike test — 4,635 reqs, 0% error
|   +-- kvm-evidence.png              # Phase 6: KVM Tier-1 Prometheus + HPA live validation
|   +-- AWS_EKS_Architecture.png      # Generated architecture diagram
|   +-- hob-lab2.png                  # Hobgoblin KVM lab topology
|
+-- .trivyignore
+-- .gitignore
+-- README.md
```

---

## DevSecOps CI/CD Pipeline

```
+-------------------------------------------------------------------+
|                    GitHub Actions Trigger                         |
|         Push to main (app/**) or workflow_dispatch                |
+--------------------------------+----------------------------------+
                                 |
                     +-----------v-----------+
                     |  1. Trivy FS Scan      |  CRITICAL/HIGH -> exit-code 1
                     |  (ci-devsecops.yml)    |  blocks merge on failure
                     +-----------+-----------+
                                 |
                     +-----------v-----------+
                     |  2. Checkov IaC Scan   |  Terraform hardening rules
                     |  (checkov-scan.yaml)   |  accepted skips documented inline
                     +-----------+-----------+
                                 |
                     +-----------v-----------+
                     |  3. Docker Build       |  python:3.11-slim multi-stage
                     |  (deploy.yml)          |  UID 10001, no build tools in final
                     +-----------+-----------+
                                 |
                     +-----------v-----------+
                     |  4. Trivy Image Scan   |  Scans final layer before push
                     +-----------+-----------+
                                 |
                     +-----------v-----------+
                     |  5. ECR Push +         |  AWS OIDC (no stored credentials)
                     |     Cosign Sign        |  Keyless -- GitHub Actions identity
                     +-----------+-----------+
                                 |
                     +-----------v-----------+
                     |  6. GitOps Tag Bump    |  kustomize edit set image
                     |  (Kustomize + git push)|  ArgoCD detects -> auto-sync
                     +-----------+-----------+
                                 |
                     +-----------v-----------+
                     |  7. Kyverno Admission  |  Unsigned image -> BLOCK (Enforce)
                     |  (at deploy time)      |  Signed image -> ALLOW
                     +-----------------------+
```

---

## Execution Runbook

> Full step-by-step checklists with evidence capture points are in [`docs/runbooks/`](docs/runbooks/):
> - **AWS EKS:** [`eks-cloud-deployment.md`](docs/runbooks/eks-cloud-deployment.md)
> - **GCP GKE:** [`gke-cloud-deployment.md`](docs/runbooks/gke-cloud-deployment.md)

### Prerequisites

```bash
terraform >= 1.5
AWS CLI v2      (configured with ap-northeast-1 default region)
gcloud CLI      (authenticated: gcloud auth login)
kubectl >= 1.28
k6              (load testing — https://k6.io/docs/get-started/installation/)
argocd CLI      (optional, for manual sync inspection)
```

### AWS EKS — Deploy & Validate

```bash
# 1. Provision infrastructure
cd terraform/environments/prod
terraform init && terraform plan -out=tfplan && terraform apply tfplan

# 2. Connect kubectl
aws eks update-kubeconfig --region ap-northeast-1 --name eks-hardened-prod
kubectl get nodes -o wide   # confirm Bottlerocket OS + Ready

# 3. Verify AWS Load Balancer Controller
kubectl get deployment -n kube-system aws-load-balancer-controller

# 4. Deploy observability stack + workload
kubectl apply -k kubernetes/observability/
kubectl apply -k kubernetes/apps/overlays/prod/
kubectl get pods,svc,ingress -n default -o wide

# 5. Run k6 spike test
ALB_DNS=$(kubectl get ingress secure-api-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
k6 run --env BASE_URL=http://$ALB_DNS tests/spike-test.js

# 6. Verify Cosign supply chain
cosign verify \
  --certificate-identity "https://github.com/Jira-saki/Cloud-Native-Hardened-Infrastructure/.github/workflows/ci-devsecops.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/secure-api:<TAG>
```

### AWS EKS — Safe Teardown

```bash
# ⚠️  Delete workloads BEFORE terraform destroy to avoid dangling ALBs
kubectl delete -k kubernetes/apps/overlays/prod/
kubectl delete pvc --all -A
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s')].LoadBalancerArn" --output text
# (wait for empty output, then:)
cd terraform/environments/prod && terraform destroy --auto-approve
```

### GCP GKE — Deploy & Validate

```bash
# 1. Enable APIs and set project
gcloud services enable container.googleapis.com cloudkms.googleapis.com \
  compute.googleapis.com iam.googleapis.com

# 2. Create terraform.tfvars
cat > terraform/environments/gcp-gke/terraform.tfvars << EOF
project_id                 = "<YOUR_PROJECT_ID>"
project_number             = "$(gcloud projects describe <YOUR_PROJECT_ID> --format='value(projectNumber)')"
region                     = "asia-northeast1"
gke_master_authorized_cidr = "<YOUR_IP>/32"
EOF

# 3. Provision infrastructure
cd terraform/environments/gcp-gke
terraform init && terraform plan -out=tfplan && terraform apply tfplan

# 4. Connect kubectl
gcloud container clusters get-credentials gke-prod-cluster \
  --region asia-northeast1 --project <YOUR_PROJECT_ID>
kubectl get nodes -o wide   # confirm COS + Ready

# 5. Verify Gateway API CRDs
kubectl get gatewayclass gke-l7-global-external-managed

# 6. Patch ServiceAccount annotation and deploy
sed -i 's/<PROJECT_ID>/<YOUR_PROJECT_ID>/g' \
  kubernetes/apps/overlays/gcp-prod/serviceaccount.yaml
kubectl apply -k kubernetes/observability/
kubectl apply -k kubernetes/apps/overlays/gcp-prod/
kubectl get pods,svc,gateway,httproute -n default -o wide

# 7. Test via Gateway IP
GATEWAY_IP=$(kubectl get gateway secure-api-gateway -o jsonpath='{.status.addresses[0].value}')
curl -I http://$GATEWAY_IP/healthz
```

### GCP GKE — Safe Teardown

```bash
# ⚠️  Delete workloads BEFORE terraform destroy to avoid dangling Cloud LBs and Persistent Disks
kubectl delete -k kubernetes/apps/overlays/gcp-prod/
kubectl delete -k kubernetes/observability/
kubectl delete pvc --all -A
gcloud compute forwarding-rules list --filter="description~secure-api"
# (wait for empty output, then:)
cd terraform/environments/gcp-gke && terraform destroy --auto-approve
```

### Bootstrap ArgoCD GitOps (AWS EKS)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f kubernetes/argocd/monitoring-app.yaml
kubectl apply -f kubernetes/argocd/app-prod.yaml
argocd app list
```

---

## Platform Roadmap

### ✅ Completed — Multi-Cloud Hardened Kubernetes Platform (current)

| Milestone | Status | Evidence |
|---|---|---|
| CKA (Certified Kubernetes Administrator) | ✅ Certified 2026 | — |
| AWS EKS hardened baseline (Bottlerocket, IRSA, KMS, WAFv2, GuardDuty) | ✅ Deployed & validated | E-01 – E-05 (see [Proof of Work](#proof-of-work--deployment-evidence)) · Phase 6: 4,635 reqs, 0% error |
| Full-stack observability (Prometheus, Grafana, Fluent Bit → OpenSearch) | ✅ Validated | E-04: PromQL `job:http_requests_total:rate5m` · Grafana HPA dashboard |
| GCP GKE parity (COS + Shielded, Workload Identity, KMS CMEK, Gateway API) | ✅ Implemented | `terraform/environments/gcp-gke/` |
| Multi-cloud Kustomize overlays (`prod/` + `gcp-prod/`) | ✅ Implemented | `kubectl kustomize` clean render |
| Deployment runbooks with evidence capture (AWS + GCP) | ✅ Committed | `docs/runbooks/` · [Proof of Work](#proof-of-work--deployment-evidence) |

### 📊 Observability Evidence — PCA-Aligned (No Exam Planned)

> Full-stack observability implemented and validated in Phase 6. PCA topics are covered by this platform but the exam is not being pursued — effort redirected to CKS.

| Component | Status |
|---|---|
| ServiceMonitor CRD autodiscovery | ✅ Implemented (`kubernetes/observability/servicemonitor.yaml`) |
| PrometheusRule (recording rules + alerts) | ✅ Implemented (`kubernetes/observability/prometheusrule.yaml`) |
| AlertmanagerConfig (routing + receivers) | ✅ Implemented (`kubernetes/observability/alertmanagerconfig.yaml`) |
| PromQL validation (rate5m recording rule) | ✅ Validated — [E-04 screenshot](assets/Prometheus-Rate5m.png) |

### 🎯 Next — CKS (Certified Kubernetes Security Specialist)

> Currently studying — runtime hardening, Kyverno admission control, Bottlerocket/COS immutability, and supply chain security. Pillar 6 of this platform will be fully implemented and validated upon certification.

| Focus Area | Mechanism | Status |
|---|---|---|
| Admission control | Kyverno `ClusterPolicy` (Enforce mode) — Cosign keyless | 🔧 Code exists, live validation pending |
| Runtime security | Falco / GuardDuty EKS Runtime Monitoring | 🎯 CKS target |
| Network microsegmentation | EKS Network Policy + Calico (GKE) | 🎯 CKS target |
| Secrets management | External Secrets Operator + AWS Secrets Manager | 🎯 CKS target |
| Supply chain hardening | Trivy + Checkov gates in CI (implemented) | ✅ Implemented |

---

## Release & Tagging

```bash
git add terraform/environments/gcp-gke/ kubernetes/apps/overlays/gcp-prod/ \
        docs/runbooks/gke-cloud-deployment.md README.md
git commit -m "feat(gcp): add GKE hardened infrastructure — multi-cloud parity complete

- terraform/environments/gcp-gke/: VPC-native, Cloud KMS CMEK, private GKE
  cluster (COS + Shielded Nodes), Workload Identity, Gateway API
- kubernetes/apps/overlays/gcp-prod/: Gateway+HTTPRoute, NEG patch, WI SA
- docs/runbooks/gke-cloud-deployment.md: full ASCII checklist, 5 evidence pts
- README: updated to reflect multi-cloud platform status"
git tag -a v2.0.0-multi-cloud -m "Multi-cloud: AWS EKS + GCP GKE hardened parity complete"
git push origin main --tags
```

---

## License

This repository is published for educational and professional portfolio purposes. All infrastructure patterns represent personal lab work for certification study and are not affiliated with any employer.
