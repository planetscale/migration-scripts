# PlanetScale Migration - AWS Cross-Account IAM Role Setup
# Static publish of Liftoff IAM generators (planetscale/liftoff-migration-reviewer PR #355)
#
# This template creates an IAM Role in your AWS account that allows PlanetScale
# to temporarily access your account for a migration proof-of-concept (POC).
# Uses cross-account role assumption with External ID for secure access.
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#
# After deployment, share the role_arn and your External ID with your
# PlanetScale contact.

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ==============================================================================
# Variables
# ==============================================================================

variable "planetscale_account_id" {
  description = "Required. PlanetScale AWS account ID (provided by PlanetScale support team)"
  type        = string

  validation {
    condition     = can(regex("^\\d{12}$", var.planetscale_account_id))
    error_message = "Must be a valid 12-digit AWS account ID."
  }
}

variable "external_id" {
  description = "Unique external ID for secure cross-account access (generate with: uuidgen or openssl rand -hex 32). Share this with PlanetScale support."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.external_id) >= 16 && length(var.external_id) <= 128
    error_message = "External ID must be 16-128 characters."
  }
}

variable "resource_prefix" {
  description = "Prefix for all resources created by PlanetScale (restricts what PlanetScale can create)"
  type        = string
  default     = "planetscale-migration"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.resource_prefix))
    error_message = "Must be lowercase alphanumeric with hyphens only."
  }
}

variable "region" {
  description = "AWS region for the provider"
  type        = string
  default     = "us-east-1"
}

# ==============================================================================
# Provider
# ==============================================================================

provider "aws" {
  region = var.region
}

# ==============================================================================
# Data Sources
# ==============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ==============================================================================
# IAM Role - Cross-Account Trust
# ==============================================================================

resource "aws_iam_role" "planetscale_migration" {
  name                 = "${var.resource_prefix}-role"
  description          = "Allows PlanetScale to restore RDS/Aurora snapshots for migration POC testing"
  max_session_duration = 43200 # 12 hours

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.planetscale_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.external_id
          }
        }
      }
    ]
  })

  tags = {
    Name      = "${var.resource_prefix}-role"
    Purpose   = "PlanetScale Migration Access"
    ManagedBy = "Terraform"
  }
}

# ==============================================================================
# IAM Policy
# ==============================================================================

resource "aws_iam_role_policy" "planetscale_migration" {
  name = "${var.resource_prefix}-policy"
  role = aws_iam_role.planetscale_migration.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudFormation account-level actions (no resource-level permissions supported).
      # CreateUploadBucket / GetTemplateSummary / ValidateTemplate are required by the
      # AWS CLI (aws cloudformation deploy / package) and the console template upload
      # flow, which stages templates in an AWS-managed cf-templates-* bucket.
      {
        Sid    = "CloudFormationAccountLevel"
        Effect = "Allow"
        Action = [
          "cloudformation:ListStacks",
          "cloudformation:CreateUploadBucket",
          "cloudformation:GetTemplateSummary",
          "cloudformation:ValidateTemplate"
        ]
        Resource = "*"
      },

      # CloudFormation describe operations (scoped to prefix)
      {
        Sid    = "CloudFormationDescribe"
        Effect = "Allow"
        Action = ["cloudformation:DescribeStacks"]
        Resource = "arn:aws:cloudformation:*:${data.aws_caller_identity.current.account_id}:stack/${var.resource_prefix}-*/*"
      },

      # CloudFormation stack + change set management.
      # Change set actions are required by "aws cloudformation deploy", which creates
      # a change set, describes/executes it, then deletes it.
      {
        Sid    = "CloudFormationStackManagement"
        Effect = "Allow"
        Action = [
          "cloudformation:CreateStack",
          "cloudformation:UpdateStack",
          "cloudformation:DeleteStack",
          "cloudformation:DescribeStackEvents",
          "cloudformation:DescribeStackResources",
          "cloudformation:DescribeStackResource",
          "cloudformation:ListStackResources",
          "cloudformation:GetTemplate",
          "cloudformation:CreateChangeSet",
          "cloudformation:DescribeChangeSet",
          "cloudformation:ExecuteChangeSet",
          "cloudformation:DeleteChangeSet",
          "cloudformation:ListChangeSets"
        ]
        Resource = "arn:aws:cloudformation:*:${data.aws_caller_identity.current.account_id}:stack/${var.resource_prefix}-*/*"
      },

      # RDS snapshot and database read permissions
      {
        Sid    = "RDSSnapshotRead"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBSnapshots",
          "rds:DescribeDBClusterSnapshots",
          "rds:DescribeDBInstances",
          "rds:DescribeDBClusters",
          "rds:DescribeDBSubnetGroups",
          "rds:DescribeDBEngineVersions",
          "rds:DescribeOrderableDBInstanceOptions",
          "rds:DescribeEvents",
          "rds:DescribeValidDBInstanceModifications",
          "rds:ListTagsForResource"
        ]
        Resource = "*"
      },

      # RDS instance and cluster creation from snapshots (restricted by prefix)
      {
        Sid    = "RDSInstanceManagement"
        Effect = "Allow"
        Action = [
          "rds:RestoreDBInstanceFromDBSnapshot",
          "rds:RestoreDBClusterFromSnapshot",
          "rds:CreateDBInstance",
          "rds:CreateDBCluster",
          "rds:ModifyDBInstance",
          "rds:ModifyDBCluster",
          "rds:RebootDBInstance",
          "rds:RebootDBCluster",
          "rds:StartDBInstance",
          "rds:StopDBInstance",
          "rds:StartDBCluster",
          "rds:StopDBCluster",
          "rds:DeleteDBInstance",
          "rds:DeleteDBCluster",
          "rds:AddTagsToResource",
          "rds:RemoveTagsFromResource"
        ]
        Resource = [
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:db:${var.resource_prefix}-*",
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:cluster:${var.resource_prefix}-*",
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:subgrp:${var.resource_prefix}-*",
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:pg:${var.resource_prefix}-*",
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:cluster-pg:${var.resource_prefix}-*",
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:snapshot:*",
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:cluster-snapshot:*"
        ]
      },

      # RDS subnet group management (restricted by prefix)
      {
        Sid    = "RDSSubnetGroupManagement"
        Effect = "Allow"
        Action = [
          "rds:CreateDBSubnetGroup",
          "rds:DeleteDBSubnetGroup",
          "rds:ModifyDBSubnetGroup",
          "rds:AddTagsToResource",
          "rds:RemoveTagsFromResource"
        ]
        Resource = "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:subgrp:${var.resource_prefix}-*"
      },

      # RDS parameter group describe operations
      {
        Sid    = "RDSParameterGroupDescribe"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBParameterGroups",
          "rds:DescribeDBClusterParameterGroups",
          "rds:DescribeDBParameters",
          "rds:DescribeDBClusterParameters",
          "rds:DescribeEngineDefaultParameters",
          "rds:DescribeEngineDefaultClusterParameters"
        ]
        Resource = "*"
      },

      # RDS parameter group management (for logical replication settings)
      {
        Sid    = "RDSParameterGroupManagement"
        Effect = "Allow"
        Action = [
          "rds:CreateDBParameterGroup",
          "rds:CreateDBClusterParameterGroup",
          "rds:ModifyDBParameterGroup",
          "rds:ModifyDBClusterParameterGroup",
          "rds:DeleteDBParameterGroup",
          "rds:DeleteDBClusterParameterGroup",
          "rds:AddTagsToResource",
          "rds:RemoveTagsFromResource"
        ]
        Resource = [
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:pg:${var.resource_prefix}-*",
          "arn:aws:rds:*:${data.aws_caller_identity.current.account_id}:cluster-pg:${var.resource_prefix}-*"
        ]
      },

      # EC2 VPC and network read permissions
      {
        Sid    = "EC2VPCRead"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSecurityGroupRules",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeRouteTables",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeNatGateways",
          "ec2:DescribeAddresses",
          "ec2:DescribeVpnGateways"
        ]
        Resource = "*"
      },

      # EC2 Security Group creation/deletion
      {
        Sid    = "EC2SecurityGroupCreateDelete"
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup"
        ]
        Resource = [
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:security-group/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:vpc/*"
        ]
      },

      # EC2 Tagging for resources we create
      {
        Sid    = "EC2Tagging"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = [
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:volume/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:security-group/*"
        ]
      },

      # EC2 Security Group rule management
      {
        Sid    = "EC2SecurityGroupRuleManagement"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress"
        ]
        Resource = [
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:security-group/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:security-group-rule/*"
        ]
      },

      # EC2 instance operations (for pgcopydb migration instances)
      {
        Sid    = "EC2InstanceManagement"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:RebootInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceAttribute",
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeImages",
          "ec2:DescribeKeyPairs",
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces"
        ]
        Resource = "*"
      },

      # EC2 volume management (for EBS volumes on pgcopydb instances)
      {
        Sid    = "EC2VolumeManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume",
          "ec2:DeleteVolume",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumeStatus",
          "ec2:ModifyVolume"
        ]
        Resource = "*"
      },

      # IAM role management for EC2 helper roles only (${var.resource_prefix}-ec2-*).
      # Does not match the migration role (${var.resource_prefix}-role).
      # No PutRolePolicy: that would allow an inline admin policy on a helper role.
      {
        Sid    = "IAMRoleManagementForEC2"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:TagRole"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.resource_prefix}-ec2-*"
      },

      # Attach/detach only the managed policies used by pgcopydb EC2 helpers
      {
        Sid    = "IAMRolePolicyAttachmentForEC2"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.resource_prefix}-ec2-*"
        Condition = {
          ArnEquals = {
            "iam:PolicyARN" = [
              "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
              "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
            ]
          }
        }
      },

      # IAM instance profile management (for EC2 helper instance profiles)
      {
        Sid    = "IAMInstanceProfileManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:ListInstanceProfiles"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.resource_prefix}-ec2-*"
      },

      # IAM PassRole for EC2 helper roles only (not the migration role)
      {
        Sid    = "IAMPassRoleForEC2"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.resource_prefix}-ec2-*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },

      # EC2 Instance Connect (for console "Connect" button)
      {
        Sid    = "EC2InstanceConnect"
        Effect = "Allow"
        Action = [
          "ec2-instance-connect:SendSSHPublicKey",
          "ec2-instance-connect:SendSerialConsoleSSHPublicKey"
        ]
        Resource = "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:instance/*"
      },

      # Systems Manager access (for EC2 Session Manager and AMI parameter resolution)
      {
        Sid    = "SSMAccess"
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeInstanceProperties",
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:StartSession",
          "ssm:TerminateSession",
          "ssm:ResumeSession"
        ]
        Resource = "*"
      },

      # CloudWatch metrics and monitoring (read-only)
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:GetDashboard",
          "cloudwatch:ListDashboards"
        ]
        Resource = "*"
      },

      # CloudWatch Logs (read-only)
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogGroupFields"
        ]
        Resource = "*"
      },

      # RDS Enhanced Monitoring, Performance Insights, and Database Insights (read-only)
      {
        Sid    = "RDSMonitoring"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBLogFiles",
          "rds:DownloadDBLogFilePortion",
          "rds:DownloadCompleteDBLogFile",
          "pi:GetResourceMetrics",
          "pi:DescribeDimensionKeys",
          "pi:GetDimensionKeyDetails",
          "pi:ListAvailableResourceMetrics",
          "pi:ListAvailableResourceDimensions",
          "pi:GetResourceMetadata",
          "pi:ListPerformanceAnalysisReports",
          "pi:GetPerformanceAnalysisReport",
          "pi:ListTagsForResource"
        ]
        Resource = "*"
      },

      # KMS read access for encrypted snapshots
      {
        Sid    = "KMSReadAccess"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:ListAliases"
        ]
        Resource = "*"
      },

      # KMS decrypt (needed if snapshot is encrypted)
      {
        Sid    = "KMSDecryptForSnapshots"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "rds.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      },

      # IAM PassRole for RDS enhanced monitoring
      {
        Sid    = "IAMPassRoleForRDS"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/rds-monitoring-role"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "monitoring.rds.amazonaws.com"
          }
        }
      },

      # S3 bucket management (for templates and audit trail)
      {
        Sid    = "S3BucketManagement"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:PutBucketVersioning",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketTagging",
          "s3:GetBucketTagging"
        ]
        Resource = "arn:aws:s3:::${var.resource_prefix}-*"
      },

      # S3 object operations
      {
        Sid    = "S3ObjectManagement"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload"
        ]
        Resource = "arn:aws:s3:::${var.resource_prefix}-*/*"
      },

      # S3 list all buckets
      {
        Sid    = "S3ListAllBuckets"
        Effect = "Allow"
        Action = ["s3:ListAllMyBuckets"]
        Resource = "*"
      },

      # S3 access to the AWS-managed CloudFormation templates bucket.
      # Both the AWS CLI ("aws cloudformation deploy") and the CloudFormation console
      # upload templates to a bucket named cf-templates-<hash>-<region>, which is
      # created on first use by cloudformation:CreateUploadBucket. The bucket name is
      # AWS-controlled, so it cannot follow the customer resource_prefix convention.
      {
        Sid    = "S3CloudFormationTemplatesBucket"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:PutBucketVersioning",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketPolicy",
          "s3:PutBucketTagging",
          "s3:GetBucketTagging"
        ]
        Resource = "arn:aws:s3:::cf-templates-*"
      },

      {
        Sid    = "S3CloudFormationTemplatesObjects"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload"
        ]
        Resource = "arn:aws:s3:::cf-templates-*/*"
      }
    ]
  })
}

# ==============================================================================
# Outputs - Share these with PlanetScale
# ==============================================================================

output "role_arn" {
  description = "IAM Role ARN — share this with PlanetScale support team"
  value       = aws_iam_role.planetscale_migration.arn
}

output "external_id_reminder" {
  description = "Share your External ID with PlanetScale support team (keep confidential)"
  value       = "Share the External ID you provided with your PlanetScale contact"
}

output "resource_prefix" {
  description = "Resource prefix that restricts what PlanetScale can create"
  value       = var.resource_prefix
}

output "role_session_duration" {
  description = "Maximum session duration"
  value       = "12 hours"
}

output "next_steps" {
  description = "What to do next"
  value       = "Share the role_arn and your External ID with PlanetScale support. PlanetScale will use this role to create database resources with names starting with '${var.resource_prefix}-'."
}

output "security_notes" {
  description = "Security information"
  value       = "This role is restricted to creating resources prefixed with \"${var.resource_prefix}-\" and requires the External ID for access. PlanetScale cannot access existing databases or resources outside this naming convention."
}

output "revoke_access" {
  description = "How to revoke PlanetScale access"
  value       = "Run 'terraform destroy' to immediately revoke all PlanetScale access. Alternatively, change the external_id variable to invalidate existing sessions."
}
