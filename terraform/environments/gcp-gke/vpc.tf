###############################################################################
# VPC — Custom VPC-Native Network (no auto subnets)
###############################################################################

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  description = "VPC-native network for GKE private cluster ${var.cluster_name}"
}

###############################################################################
# Subnet — with secondary IP ranges for Pods and Services
###############################################################################

resource "google_compute_subnetwork" "gke_subnet" {
  project       = var.project_id
  name          = "${var.cluster_name}-subnet"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = "10.0.0.0/24"

  # Alias IP ranges are required for VPC-native (IP masquerade-free) clusters
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.100.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.101.0.0/20"
  }

  # Enable Private Google Access so nodes can reach Google APIs without a public IP
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

###############################################################################
# Cloud Router — required for Cloud NAT
###############################################################################

resource "google_compute_router" "nat_router" {
  project = var.project_id
  name    = "${var.cluster_name}-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

###############################################################################
# Cloud NAT — provides outbound internet access for private nodes
# (node pool has no external IPs; egress routes through NAT)
###############################################################################

resource "google_compute_router_nat" "nat" {
  project                            = var.project_id
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

###############################################################################
# Firewall — Explicit intra-cluster allow rule (CKV2_GCP_18)
# GCP best practice: define explicit firewall rules; do not rely on the
# implicit default-allow rules that are created with a new VPC.
###############################################################################

resource "google_compute_firewall" "gke_allow_internal" {
  project     = var.project_id
  name        = "${var.cluster_name}-allow-internal"
  network     = google_compute_network.vpc.name
  description = "Allow internal traffic between GKE nodes, pods, and services. Satisfies CKV2_GCP_18."
  direction   = "INGRESS"
  priority    = 1000

  # Allow TCP, UDP, and ICMP within the cluster's own address space only.
  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  # Restrict to cluster-internal CIDRs — no public ingress permitted.
  source_ranges = [
    "10.0.0.0/24",   # node subnet (gke_subnet primary range)
    "10.100.0.0/16", # pod secondary range
    "10.101.0.0/20", # services secondary range
  ]

  target_tags = ["gke-node"]
}

###############################################################################
# Firewall — Deny all other ingress (explicit default-deny)
# Ensures no implicit rules allow unexpected traffic into the VPC.
###############################################################################

resource "google_compute_firewall" "gke_deny_all_ingress" {
  project     = var.project_id
  name        = "${var.cluster_name}-deny-all-ingress"
  network     = google_compute_network.vpc.name
  description = "Default-deny all ingress not matched by a higher-priority allow rule."
  direction   = "INGRESS"
  priority    = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
}
