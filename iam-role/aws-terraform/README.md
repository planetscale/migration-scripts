# PlanetScale Migration — AWS IAM Role Setup (Terraform)

## What This Does

This Terraform template creates an **IAM Role** in your AWS account that allows
PlanetScale to temporarily access your account for a migration proof-of-concept (POC).

PlanetScale uses this role to restore a copy of your database from a snapshot, set up
migration infrastructure, and run a test migration to PlanetScale — all without needing
long-term credentials or direct access to your production systems.

This is the customer cross-account access role. It is not the pgcopydb EC2 instance
role in [`pgcopydb-templates`](../../pgcopydb-templates).

## What PlanetScale CAN Do

All actions are restricted to resources named with your chosen prefix (default: `planetscale-migration-*`):

| Action | Scope |
|---|---|
| Restore RDS/Aurora snapshots | Only to instances named `planetscale-migration-*` |
| Create/manage EC2 instances | Only instances named `planetscale-migration-*` |
| Create security groups | For migration network access |
| Create RDS parameter groups | Only named `planetscale-migration-*` |
| Read VPC/subnet info | Read-only (needed to place resources correctly) |
| Read CloudWatch metrics/logs | Read-only (for monitoring migration progress) |
| Read RDS Enhanced Monitoring, Performance Insights, and Database Insights | Read-only (`pi:` list/get/describe; no create/delete reports or tag writes) |
| Create S3 buckets | Only buckets named `planetscale-migration-*` |
| Use KMS keys | Only via RDS (for encrypted snapshots) |

## What PlanetScale CANNOT Do

- Access or modify your existing databases, EC2 instances, or other resources
- Create resources outside the naming prefix
- Modify your VPCs, subnets, or network configuration
- Access any S3 buckets not created by PlanetScale
- Access the role without the External ID (a shared secret you control)
- Maintain access after you run `terraform destroy`

## How to Deploy

### Prerequisites
- [Terraform](https://developer.hashicorp.com/terraform/install) installed (v1.0+)
- AWS credentials configured (`aws configure` or environment variables)
- A VPC with subnets where migration resources will be created

### Steps

1. **Create a `terraform.tfvars` file** with your values:
   ```hcl
   planetscale_account_id = "PLANETSCALE-ACCOUNT-ID"  # Provided by PlanetScale
   external_id            = "YOUR-GENERATED-SECRET"    # Generate with: uuidgen
   resource_prefix        = "planetscale-migration"    # Or customize
   region                 = "us-east-1"                # Your AWS region
   ```

2. **Deploy**
   ```bash
   terraform init
   terraform plan    # Review what will be created
   terraform apply   # Type "yes" to confirm
   ```

3. **Share with PlanetScale**
   - The `role_arn` output from Terraform
   - The External ID you generated in step 1

## How to Revoke Access

Run `terraform destroy` to **immediately** revoke all PlanetScale access:

```bash
terraform destroy
```

Alternatively, you can change the `external_id` variable and run `terraform apply` to
invalidate existing sessions without deleting the role.

## Questions?

Contact your PlanetScale migration team representative if you have any questions
about the permissions or deployment process.
