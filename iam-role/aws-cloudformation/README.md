# PlanetScale Migration — AWS IAM Role Setup

## What This Does

This CloudFormation template creates an IAM Role in your AWS account that allows
PlanetScale to temporarily access your account for a migration proof-of-concept (POC).

PlanetScale uses this role to restore a copy of your database from a snapshot, set up
migration infrastructure, and run a test migration to PlanetScale — all without needing
long-term credentials or direct access to your production systems.

This is the customer **cross-account access role**, not the [pgcopydb EC2 instance role](../../pgcopydb-templates/aws-cloudformation/).

## What PlanetScale CAN Do

All write actions are restricted to resources named with your chosen prefix (default: `planetscale-migration-*`):

| Action | Scope |
|---|---|
| Restore RDS/Aurora snapshots | Only to instances named `planetscale-migration-*` |
| Create/manage EC2 instances | Only instances named `planetscale-migration-*` |
| Create security groups | For migration network access |
| Create RDS parameter groups | Only named `planetscale-migration-*` |
| Read VPC/subnet info | Read-only (needed to place resources correctly) |
| Read CloudWatch metrics/logs | Read-only (for monitoring migration progress) |
| Read Performance Insights / Database Insights | Read-only (`pi:` list/get/describe; no create/delete/tag) |
| Create S3 buckets | Only buckets named `planetscale-migration-*` |
| Use KMS keys | Only via RDS (for encrypted snapshots) |

## What PlanetScale CANNOT Do

- Access or modify your existing databases, EC2 instances, or other resources
- Create resources outside the naming prefix
- Modify your VPCs, subnets, or network configuration
- Access any S3 buckets not created by PlanetScale
- Access the role without the External ID (a shared secret you control)
- Maintain access after you delete the CloudFormation stack

## How to Deploy

### Prerequisites

- AWS account with CloudFormation access
- PlanetScale AWS account ID (from your PlanetScale contact)
- A unique External ID (`uuidgen` or `openssl rand -hex 32`)

### Steps

1. **Open the AWS CloudFormation Console**
   - Go to [CloudFormation](https://console.aws.amazon.com/cloudformation) in your AWS account

2. **Create a new stack**
   - Click "Create stack" → "With new resources"
   - Upload the `planetscale-iam-role.yaml` template

3. **Fill in the parameters**
   - **PlanetScale Account ID**: Provided by your PlanetScale contact
   - **External ID**: Generate a unique secret (e.g., run `uuidgen` in your terminal)
   - **Resource Prefix**: Leave as default or customize (controls what PlanetScale can name resources)

4. **Deploy**
   - Check the "I acknowledge that AWS CloudFormation might create IAM resources" box
   - Click "Create stack"
   - Wait for status to show `CREATE_COMPLETE` (~2 minutes)

   Or via the CLI:

   ```bash
   aws cloudformation create-stack \
     --stack-name planetscale-migration-iam-role \
     --template-body file://planetscale-iam-role.yaml \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameters \
       ParameterKey=PlanetScaleAccountId,ParameterValue=PLANETSCALE-ACCOUNT-ID \
       ParameterKey=ExternalId,ParameterValue=YOUR-GENERATED-SECRET
   ```

5. **Share with PlanetScale**
   - Go to the "Outputs" tab of the stack
   - Share the **Role ARN** and your **External ID** with your PlanetScale contact

## How to Revoke Access

Delete the CloudFormation stack to immediately revoke all PlanetScale access:

```bash
aws cloudformation delete-stack --stack-name planetscale-migration-iam-role
```

Or delete it from the CloudFormation Console → select stack → Delete.

Alternatively, you can change the External ID parameter to invalidate existing sessions
without deleting the stack.

## Questions?

Contact your PlanetScale migration team representative if you have any questions
about the permissions or deployment process. See also the [pgcopydb import docs](https://planetscale.com/docs/postgres/imports/postgres-migrate-pgcopydb).
