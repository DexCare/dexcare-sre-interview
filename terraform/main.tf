# Tenant Infrastructure Module
# Creates per-tenant resources for namespace isolation in our multi-tenant EKS cluster

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

variable "tenant_name" {
  type    = string
  default = ""
}

variable "environment" {
  type    = string
  default = "production"
}

variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type        = string
  description = "OIDC provider ARN for the EKS cluster"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for security group creation"
}

variable "elasticache_subnet_group" {
  type        = string
  description = "ElastiCache subnet group name"
}

variable "eks_node_security_group_id" {
  type        = string
  description = "Security group ID for EKS worker nodes"
}

variable "db_connection_string" {
  type = string
}

variable "allowed_s3_actions" {
  type    = list(string)
  default = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
}

# Tenant namespace
resource "kubernetes_namespace" "tenant" {
  metadata {
    name = var.tenant_name
    labels = {
      tenant      = var.tenant_name
      environment = var.environment
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}

# S3 bucket for tenant PHI data
resource "aws_s3_bucket" "tenant_data" {
  bucket = "${var.tenant_name}-patient-data-${var.environment}"

  tags = {
    Tenant      = var.tenant_name
    Environment = var.environment
    DataClass   = "phi"
    env         = "prod"
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

resource "aws_s3_bucket_versioning" "tenant_data" {
  bucket = aws_s3_bucket.tenant_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tenant_data" {
  bucket = aws_s3_bucket.tenant_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tenant_encryption.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tenant_data" {
  bucket = aws_s3_bucket.tenant_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "tenant_data" {
  bucket        = aws_s3_bucket.tenant_data.id
  target_bucket = aws_s3_bucket.tenant_data.id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_policy" "tenant_data" {
  bucket = aws_s3_bucket.tenant_data.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCrossAccountBackup"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::491832576410:role/backup-service-role" }
        Action    = ["s3:GetObject", "s3:ListBucket"]
        Resource  = [
          aws_s3_bucket.tenant_data.arn,
          "${aws_s3_bucket.tenant_data.arn}/*"
        ]
      }
    ]
  })
}

# IAM role for tenant workloads (IRSA)
resource "aws_iam_role" "tenant_workload" {
  name = "${var.tenant_name}-${var.environment}-workload"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "${replace(var.oidc_provider_arn, "/^arn:aws:iam::\\d+:oidc-provider\\//", "")}:sub" = "system:serviceaccount:${var.tenant_name}:*"
          }
        }
      }
    ]
  })

  tags = {
    Tenant      = var.tenant_name
    Environment = var.environment
    DataClass   = "phi"
    env         = "prod"
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

# Policy for tenant S3 access
resource "aws_iam_role_policy" "tenant_s3_access" {
  name = "${var.tenant_name}-s3-access"
  role = aws_iam_role.tenant_workload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = var.allowed_s3_actions
        Resource = [
          aws_s3_bucket.tenant_data.arn,
          "${aws_s3_bucket.tenant_data.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.tenant_encryption.arn
      }
    ]
  })
}

# ElastiCache (Redis) for tenant session data
resource "aws_elasticache_replication_group" "tenant_sessions" {
  replication_group_id = "${var.tenant_name}-${var.environment}-sessions"
  description          = "Session cache for ${var.tenant_name}"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  port                 = 6379
  engine_version       = "7.0"

  subnet_group_name    = var.elasticache_subnet_group
  security_group_ids   = [aws_security_group.tenant_redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = aws_kms_key.tenant_encryption.arn

  automatic_failover_enabled = false

  tags = {
    Tenant      = var.tenant_name
    Environment = var.environment
    DataClass   = "phi"
    env         = "prod"
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

resource "aws_security_group" "tenant_redis" {
  name_prefix = "${var.tenant_name}-${var.environment}-redis-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Tenant      = var.tenant_name
    Environment = var.environment
    DataClass   = "phi"
    env         = "prod"
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

# Initialize tenant database schema
resource "null_resource" "db_schema_init" {
  provisioner "local-exec" {
    command = "${path.module}/scripts/init-schema.sh"
    environment = {
      TENANT_NAME   = var.tenant_name
      DB_CONNECTION = var.db_connection_string
    }
  }

  triggers = {
    schema_version = "3"
  }
}

# Network policy to isolate tenant
resource "kubernetes_network_policy" "tenant_isolation" {
  metadata {
    name      = "${var.tenant_name}-isolation"
    namespace = kubernetes_namespace.tenant.metadata[0].name
  }

  spec {
    pod_selector {}

    ingress {
      from {
        namespace_selector {
          match_labels = {
            tenant = var.tenant_name
          }
        }
      }
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ingress-nginx"
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}

# KMS key for tenant encryption
resource "aws_kms_key" "tenant_encryption" {
  description             = "Encryption key for ${var.tenant_name} (${var.environment})"
  enable_key_rotation     = true
  deletion_window_in_days = 1

  policy = data.aws_iam_policy_document.kms_policy.json

  tags = {
    Tenant      = var.tenant_name
    Environment = var.environment
    DataClass   = "phi"
    env         = "prod"
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

resource "aws_kms_alias" "tenant_encryption" {
  name          = "alias/${var.tenant_name}-${var.environment}"
  target_key_id = aws_kms_key.tenant_encryption.key_id
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms_policy" {
  statement {
    sid       = "RootAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "TenantWorkloadAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.tenant_workload.arn]
    }
  }
}

output "tenant_role_arn" {
  value = aws_iam_role.tenant_workload.arn
}

output "bucket_name" {
  value = aws_s3_bucket.tenant_data.bucket
}

output "kms_key_arn" {
  value = aws_kms_key.tenant_encryption.arn
}

output "namespace" {
  value = kubernetes_namespace.tenant.metadata[0].name
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.tenant_sessions.primary_endpoint_address
}

output "db_connection_string" {
  value = var.db_connection_string
}
