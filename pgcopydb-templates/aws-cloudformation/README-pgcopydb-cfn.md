# PlanetScale Migration — pgcopydb Migration Instance (AWS CloudFormation)

## What This Does

This CloudFormation template creates an EC2 instance pre-configured with
[pgcopydb](https://github.com/planetscale/pgcopydb), the tool PlanetScale uses to migrate
your PostgreSQL data. The instance runs Ubuntu 24.04 and pulls the latest
[PlanetScale migration helper scripts](https://github.com/planetscale/migration-scripts)
at boot.

## What Gets Created

- An EC2 instance with pgcopydb and PostgreSQL client tools installed
- An EBS volume for migration working data
- A security group for network access
- An IAM instance profile with SSM Session Manager access
- Migration helper scripts from `github.com/planetscale/migration-scripts` in `/home/ubuntu/`

## How to Deploy

### Prerequisites
- VPC ID and a subnet ID where the instance should run
- The source database must be network-accessible from this subnet

### Steps

1. **Upload** the `pgcopydb-migration-instance.yaml` template to CloudFormation
2. **Fill in** VPC ID, Subnet ID, instance type, and volume size
3. **Restrict SSH access** by entering your public IP in the **YourPublicIP** parameter
   (get it from [icanhazip.com](https://icanhazip.com)). Leave blank to allow SSH from anywhere (not recommended).
4. **Deploy** and wait for completion (~10 minutes)
5. **Connect** via SSM Session Manager (no SSH key needed):
   ```bash
   aws ssm start-session --target INSTANCE_ID
   ```
   Or via EC2 Instance Connect (browser-based SSH, no key needed — open the instance in the EC2 console and click **Connect**).

## How to Tear Down

Delete the CloudFormation stack to remove the instance and all associated resources:

```bash
aws cloudformation delete-stack --stack-name YOUR_STACK_NAME
```

## Questions?

Visit [PlanetScale documentation](https://planetscale.com/docs) for more information.
