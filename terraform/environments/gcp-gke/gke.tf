###############################################################################
# GKE Cluster — Private Standard Cluster (Hardened Configuration)
# GCP parity to: AWS EKS (private endpoint, Bottlerocket, KMS encryption)
###############################################################################

resource "google_container_cluster" "primary" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.region

  # ── Network ───────────────────────────────────────────────────────────────
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.gke_subnet.name

  # VPC-Native networking (alias IPs) — equivalent to AWS VPC CNI
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # ── Hardening: Private Nodes + API Endpoint ───────────────────────────────
  # private_endpoint = false: The master API is reachable via its public IP
  # but restricted to master_authorized_networks. Private nodes have no
  # external IPs — they egress via Cloud NAT defined in vpc.tf.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.32/28"
  }

  # Restrict who can reach the Kubernetes API server
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.gke_master_authorized_cidr
      display_name = "allowed-workstation"
    }
  }

  # ── Hardening: Disable legacy auth ───────────────────────────────────────
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # ── Release Channel ───────────────────────────────────────────────────────
  # REGULAR channel: production-grade, managed minor version upgrades
  release_channel {
    channel = "REGULAR"
  }

  # ── Workload Identity ─────────────────────────────────────────────────────
  # GCP parity to: AWS IRSA (IAM Role for Service Accounts)
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # ── Database Encryption (etcd CMEK) ──────────────────────────────────────
  # GCP parity to: AWS KMS envelope encryption on EKS secrets
  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.gke_etcd.id
  }

  # ── Hardening: Security Posture & Binary Authorization ────────────────────
  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC"
  }

  # ── Hardening: Shielded Nodes (cluster-wide default) ──────────────────────
  # GCP parity to: Bottlerocket OS hardened kernel on EKS
  enable_shielded_nodes = true

  # ── Gateway API — enables GKE Gateway resources for Cloud LB with NEGs ────
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # ── Addons ────────────────────────────────────────────────────────────────
  addons_config {
    # HTTP Load Balancing is required for Gateway API and Ingress with NEGs
    http_load_balancing {
      disabled = false
    }
    # Horizontal Pod Autoscaling (required for HPA resources)
    horizontal_pod_autoscaling {
      disabled = false
    }
    # Network Policy (Calico) for pod-level microsegmentation
    network_policy_config {
      disabled = false
    }
  }

  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # ── Logging & Monitoring (Cloud Operations) ───────────────────────────────
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "APISERVER", "CONTROLLER_MANAGER", "SCHEDULER"]
    managed_prometheus {
      enabled = false # We use our own kube-prometheus-stack (same as EKS)
    }
  }

  # ── Maintenance Window ────────────────────────────────────────────────────
  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T17:00:00Z" # 02:00 JST
      end_time   = "2024-01-01T21:00:00Z" # 06:00 JST
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  # Remove the default node pool — we manage our own below for full control
  remove_default_node_pool = true
  initial_node_count       = 1

  depends_on = [
    google_kms_crypto_key_iam_binding.gke_etcd_encrypter,
    google_compute_router_nat.nat,
  ]
}

###############################################################################
# Node Pool — Shielded COS_CONTAINERD nodes with Workload Identity
# GCP parity to: Bottlerocket node group on EKS (ami_type = BOTTLEROCKET_x86_64)
###############################################################################

resource "google_container_node_pool" "primary" {
  project    = var.project_id
  name       = "${var.cluster_name}-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = var.node_count

  # ── Autoscaling ──────────────────────────────────────────────────────────
  # GCP built-in Cluster Autoscaler (parity to Karpenter on EKS)
  autoscaling {
    min_node_count = 2
    max_node_count = 5
  }

  # ── Upgrade Strategy ─────────────────────────────────────────────────────
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.node_machine_type

    # ── OS: Container-Optimized OS (hardened, minimal, immutable)
    # GCP parity to: Bottlerocket OS on EKS
    image_type = "COS_CONTAINERD"

    disk_type    = "pd-ssd"
    disk_size_gb = 50

    # ── Shielded Instance: Secure Boot + vTPM + Integrity Monitoring
    # GCP parity to: Bottlerocket verified boot / dm-verity on EKS
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # ── Workload Identity on node level ──────────────────────────────────
    # GCP parity to: IRSA with eks-pod-identity-agent addon on EKS
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Broad cloud-platform scope; Workload Identity further restricts per-pod
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # ── Node Labels ───────────────────────────────────────────────────────
    labels = {
      env        = "prod"
      managed-by = "terraform"
      node-pool  = "${var.cluster_name}-node-pool"
    }

    # ── Node Taints (none for general workloads) ──────────────────────────

    metadata = {
      # Disable legacy metadata server endpoints for security
      disable-legacy-endpoints = "true"
    }

    tags = ["gke-node", var.cluster_name]
  }
}
