from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EKS, EC2
from diagrams.aws.network import ALB, InternetGateway, VPC, NATGateway
from diagrams.aws.security import WAF, KMS, IAMRole
from diagrams.aws.management import Cloudwatch
from diagrams.k8s.compute import Pod
from diagrams.k8s.clusterconfig import HPA
from diagrams.k8s.network import NetworkPolicy
from diagrams.k8s.rbac import ServiceAccount
from diagrams.onprem.monitoring import Prometheus, Grafana

graph_attr = {
    "fontsize": "16",
    "bgcolor": "white",
    "pad": "0.5"
}

with Diagram(
    "AWS EKS Hardened Platform — Zero-Trust & eBPF Reference Architecture",
    filename="assets/EKS_Hardened_Architecture",
    show=False,
    direction="LR",
    graph_attr=graph_attr
):
    igw = InternetGateway("Internet Gateway")
    waf = WAF("AWS WAFv2")
    
    with Cluster("AWS VPC (10.0.0.0/16)"):
        with Cluster("Public Subnet (DMZ)"):
            alb = ALB("AWS ALB\n(IP Target Mode)")
            nat = NATGateway("NAT Gateway")
            igw >> waf >> alb

        with Cluster("Private Subnet — Hardened EKS Cluster"):
            control_plane = EKS("EKS Control Plane\n(Private Endpoint)")
            kms = KMS("KMS CMK\n(etcd Envelope Enc)")
            kms - Edge(style="dashed", label="encrypts") - control_plane

            with Cluster("Bottlerocket Worker Nodes (Immutable OS)"):
                with Cluster("Namespace: dev-sandbox (Multi-Tenant)"):
                    netpol = NetworkPolicy("NetworkPolicy\n(eBPF Dropped)")
                    app_pod = Pod("secure-api\n(Non-Root / Read-Only)")
                    hpa = HPA("HPA Engine\n(CPU Target 60%)")
                    irsa = IAMRole("IRSA\n(Least Privilege)")
                    
                    irsa >> app_pod
                    hpa >> app_pod
                    netpol - Edge(color="red", style="dashed", label="isolated") - app_pod

            with Cluster("Observability & Autoscaling"):
                prom = Prometheus("Prometheus\nOperator")
                grafana = Grafana("Grafana\nDashboards")
                karpenter = EC2("Karpenter JIT\n(Bottlerocket Nodes)")
                
                app_pod >> Edge(label="scrapes /metrics") >> prom >> grafana
                hpa >> Edge(style="dotted", label="triggers JIT") >> karpenter

        with Cluster("Centralized Audit Tier"):
            cw = Cloudwatch("CloudWatch Logs\n(VPC & Container Logs)")
            app_pod >> Edge(style="dashed", label="Fluent Bit") >> cw

        alb >> Edge(label="direct pod IP") >> app_pod