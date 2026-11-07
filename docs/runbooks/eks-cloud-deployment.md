================================================================================
RUNBOOK: AWS EKS Hardened Infrastructure - Deployment & Teardown
Step-by-Step Checklist with Evidence Capture (Proof-of-Work)
Last Updated : 2026-11-07
Purpose      : Cloud Deployment Guide + Portfolio Evidence Collection
================================================================================

Phase 1: Pre-Flight & Provisioning (Terraform)
--------------------------------------------------------------------------------
[ ] 1.1 Verify AWS CLI Credentials and Context
    $ aws sts get-caller-identity

[ ] 1.2 Run Terraform to Provision Infrastructure
    $ cd terraform/environments/prod
    $ terraform init
    $ terraform plan -out=tfplan
    $ terraform apply tfplan

[ ] SCREENSHOT #1 - Terraform Apply Complete (E-01)
    Capture terminal showing:
    Apply complete! Resources: XX added, 0 changed, 0 destroyed.
    Outputs table showing: cluster_endpoint, cluster_name, vpc_id

================================================================================
Phase 2: Cluster Connectivity & Bottlerocket Nodes
--------------------------------------------------------------------------------
[ ] 2.1 Update Kubeconfig
    $ aws eks update-kubeconfig --region ap-northeast-1 --name eks-hardened-prod

[ ] 2.2 Verify Control Plane and Nodes Status
    $ kubectl get nodes -o wide

[ ] SCREENSHOT #2 - Bottlerocket OS Verification (E-02)
    Capture output of kubectl get nodes -o wide
    Highlight OS-IMAGE column showing "Bottlerocket OS"
    All nodes must show status "Ready"

================================================================================
Phase 3: Workload & AWS Load Balancer Controller (Prod Overlay)
--------------------------------------------------------------------------------
[ ] 3.0 Verify AWS Load Balancer Controller is Running
    $ kubectl get deployment -n kube-system aws-load-balancer-controller

[ ] 3.1 Deploy Production Overlay via Kustomize
    $ kubectl apply -k kubernetes/apps/overlays/prod/

[ ] 3.2 Verify Pods, Services, and AWS ALB Ingress
    $ kubectl get pods,svc,ingress -n secure-api -o wide

    NOTE: Wait 2-3 minutes for AWS ALB to provision.
          ADDRESS should show k8s-secureapi-...elb.ap-northeast-1.amazonaws.com

[ ] SCREENSHOT #3 - Production Ingress & Pods (E-03)
    Capture terminal showing Pod "secure-api" in 1/1 Running state
    All replicas running, and Ingress showing AWS ALB URL in ADDRESS field

================================================================================
Phase 4: Observability, Metrics & Alert Pipeline
--------------------------------------------------------------------------------
[ ] 4.0 Deploy Observability Stack & PrometheusRules
    $ kubectl apply -k kubernetes/observability/
    $ kubectl get pods -n monitoring

[ ] 4.1 Send Test Traffic via Public ALB URL
    $ ALB_URL=$(kubectl get ingress secure-api-ingress -n secure-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    $ curl -I http://$ALB_URL/healthz

[ ] 4.2 Verify Prometheus Scrape Target (up == 1)
    $ kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
    $ curl -sG --data-urlencode 'query=up{service="secure-api-svc"}' http://localhost:9090/api/v1/query | jq .data.result

[ ] 4.3 Verify Recording Rules via Prometheus
    $ curl -sG --data-urlencode 'query=job:http_requests_total:rate5m' http://localhost:9090/api/v1/query | jq .data.result

[ ] SCREENSHOT #4 - End-to-End Observability (E-04)
    Capture Prometheus Web UI or Terminal jq output showing:
    query result: job:http_requests_total:rate5m
    Target on cloud with status UP

================================================================================
Phase 5: Two-Tier Autoscaling Verification (k6 Spike Test)
--------------------------------------------------------------------------------
[ ] 5.1 Execute k6 Spike Test against ALB Endpoint
    $ k6 run --vus 60 --duration 2m tests/load/k6-spike-test.js

[ ] 5.2 Monitor HPA Pod Scale-Out (2 -> 8 Replicas)
    $ kubectl get hpa -n secure-api -w

[ ] 5.3 Verify Karpenter Node Provisioning
    $ kubectl get nodes -l karpenter.sh/nodepool -w

[ ] SCREENSHOT #5 - SRE Reliability & HPA Result (E-06)
    Capture terminal showing 0.00% error rate across 4,635+ requests
    and kubectl get hpa showing scale-out to 8 replicas

================================================================================
Phase 6: Clean Teardown & Cost Elimination (Destroy)
--------------------------------------------------------------------------------
[!!! WARNING - SRE BEST PRACTICE - READ BEFORE PROCEEDING !!!]
DO NOT run terraform destroy while Ingress, LoadBalancer Services, or PVCs
exist in K8s. The AWS Load Balancer Controller and CSI drivers create
external AWS resources that cause VPC and Subnet dependency locks.

[ ] 6.1 Delete Workloads and Ingress (Allows Controller to Deprovision ALB)
    $ kubectl delete -k kubernetes/apps/overlays/prod/

[ ] 6.2 Release all EBS Volumes by Deleting PVCs Across All Namespaces
    $ kubectl delete pvc --all -A

[ ] 6.3 Wait for ALB to be Fully Deleted in AWS Console or CLI
    $ aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?contains(LoadBalancerName, 'k8s')].LoadBalancerArn" \
        --output text
    NOTE: No ARN should remain before proceeding to next step.

[ ] 6.4 Kill Any Remaining Port-Forward Processes
    $ pkill -f "port-forward"

[ ] 6.5 Destroy All Infrastructure via Terraform
    $ cd terraform/environments/prod
    $ terraform destroy --auto-approve

[ ] SCREENSHOT #6 - Complete Teardown (E-05)
    Capture final terminal line showing:
    Destroy complete! Resources: XX destroyed.
    Confirms zero lingering resources and immediate cost elimination.

================================================================================
Evidence Summary Table
--------------------------------------------------------------------------------
IMG  Description                           Verification Purpose
---  ------------------------------------  -------------------------------------
01   Terminal: terraform apply complete    Verify IaC automation on AWS
02   Terminal: kubectl get nodes -o wide   Verify Bottlerocket OS on EKS
03   Terminal: kubectl get ingress,pods    Verify AWS ALB Ingress & Pods ready
04   Prometheus UI: PromQL rate5m          Verify Full-stack Observability
05   Terminal: terraform destroy complete  Verify Clean Teardown & Cost Control
06   Terminal: k6 Spike & HPA Results      Verify 2-Tier Autoscaling (0% errors)
================================================================================
END OF RUNBOOK
