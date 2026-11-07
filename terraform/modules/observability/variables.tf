variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "data_subnet_ids" {
  description = "Subnets for OpenSearch"
  type        = list(string)
}

variable "environment" {
  description = "Deployment environment (e.g. prod, staging)"
  type        = string
  default     = "prod"
}

variable "cluster_name" {
  description = "EKS Cluster Name"
  type        = string
  default     = "eks-hardened-prod"
}

variable "kms_key_arn" {
  description = "KMS Key ARN for CloudWatch Log Group encryption"
  type        = string
  default     = null
}