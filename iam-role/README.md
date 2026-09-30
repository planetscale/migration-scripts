# Customer AWS IAM role for PlanetScale migrations

Cross-account IAM role that PlanetScale assumes in the customer AWS account for migration work: snapshot restore, migration infrastructure, and read-only RDS monitoring (Enhanced Monitoring, Performance Insights, and Database Insights).

This is **not** the [pgcopydb instance](../pgcopydb-templates/) EC2 role (CloudWatch Agent + SSM). Do not put these `pi:` actions on the instance role.

CloudFormation and Terraform here are the static publish of Liftoff's IAM generators (`planetscaleIamRole.js` / `planetscaleIamRoleTerraform.js`), including the Database Insights read-only `pi:` actions from [liftoff-migration-reviewer#355](https://github.com/planetscale/liftoff-migration-reviewer/pull/355).

## Parameters

Both templates take:

- **PlanetScale AWS account ID** — provided by PlanetScale support
- **External ID** — customer-generated shared secret (`uuidgen` or `openssl rand -hex 32`). Required on `sts:AssumeRole`. Share it with PlanetScale; keep it confidential.
- **Resource prefix** — defaults to `planetscale-migration`; write actions are scoped to names with this prefix

After deploy, share the role ARN and External ID with PlanetScale.

## Templates

| Template | Tool | README |
|----------|------|--------|
| [AWS CloudFormation](./aws-cloudformation/) | CloudFormation | [README](./aws-cloudformation/README.md) |
| [AWS Terraform](./aws-terraform/) | Terraform | [README](./aws-terraform/README.md) |

For the pgcopydb migration instance itself, see [pgcopydb-templates](../pgcopydb-templates/) and the [pgcopydb import docs](https://planetscale.com/docs/postgres/imports/postgres-migrate-pgcopydb).
