data "aws_caller_identity" "current" {}

# 1. IAM Policy Document สำหรับ KMS Keys
data "aws_iam_policy_document" "kms_key_policy" {
  #checkov:skip=CKV_AWS_356: "KMS Key Policy requires wildcard resource per AWS specifications"
  #checkov:skip=CKV_AWS_111: "KMS Key Policy root account statement requires write permissions for key administration"
  #checkov:skip=CKV_AWS_109: "KMS Key Policy requires permissions management statement for root user"

  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}


resource "aws_kms_key" "this" {
  description         = "KMS Key for Infrastructure Hardening"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.kms_key_policy.json
}


# CloudWatch Log Group for VPC Flow Logs
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flow-logs-${var.environment}"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# CloudWatch Log Group for Application & Container Logs (via Fluent Bit)
resource "aws_cloudwatch_log_group" "container_logs" {
  name              = "/aws/eks/${var.cluster_name}/containers"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
