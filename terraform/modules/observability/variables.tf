variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "data_subnet_ids" {
  description = "Subnets for OpenSearch"
  type        = list(string)
}
