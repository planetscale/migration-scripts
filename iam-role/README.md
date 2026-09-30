# Customer PlanetScale migration IAM role (AWS)

Cross-account IAM role customers deploy so PlanetScale can run a migration POC in their AWS account. PlanetScale assumes this role with an External ID. It is **not** the pgcopydb EC2 instance role.

The EC2 instance role lives in [pgcopydb-templates](../pgcopydb-templates) and only attaches `CloudWatchAgentServerPolicy` and `AmazonSSMManagedInstanceCore`. Do not put `pi:` (Performance Insights / Database Insights) on that instance role.

## Parameters

Both templates take:

- **PlanetScale AWS account ID** — provided by PlanetScale support
- **External ID** — customer-generated shared secret (`uuidgen` or `openssl rand -hex 32`). Required on `sts:AssumeRole`. Share it with PlanetScale; keep it confidential.
- **Resource prefix** — defaults to `planetscale-migration`; write actions are scoped to names with this prefix

After deploy, share the role ARN and External ID with PlanetScale.

## Templates

| Template | Tool | README |
|----------|------|--------|
| [AWS CloudFormation](./aws-cloudformation/planetscale-iam-role.yaml) | CloudFormation | [README](./aws-cloudformation/README.md) |
| [AWS Terraform](./aws-terraform/planetscale-iam-role.tf) | Terraform | [README](./aws-terraform/README.md) |

These are a static publish of the Liftoff generators (`planetscaleIamRole.js` / `planetscaleIamRoleTerraform.js`), including the Database Insights read-only `pi:` actions from [liftoff-migration-reviewer PR #355](https://github.com/planetscale/liftoff-migration-reviewer/pull/355).

## RDSMonitoring (`pi:` actions)

Sid `RDSMonitoring` comment: **RDS Enhanced Monitoring, Performance Insights, and Database Insights (read-only).**

Read-only Performance Insights / Database Insights actions on this customer role (nine total):

- `pi:GetResourceMetrics`
- `pi:DescribeDimensionKeys`
- `pi:GetDimensionKeyDetails`
- `pi:ListAvailableResourceMetrics`
- `pi:ListAvailableResourceDimensions`
- `pi:GetResourceMetadata`
- `pi:ListPerformanceAnalysisReports`
- `pi:GetPerformanceAnalysisReport`
- `pi:ListTagsForResource`

Not included: `CreatePerformanceAnalysisReport`, `DeletePerformanceAnalysisReport`, `TagResource`, `UntagResource`.
