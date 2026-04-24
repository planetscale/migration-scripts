# PlanetScale Migration — pgcopydb Migration Instance (AWS Terraform)

## What This Does

This Terraform template creates an EC2 instance pre-configured with
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
- [Terraform](https://developer.hashicorp.com/terraform/install) installed (v1.0+)
- VPC ID and a subnet ID
- AWS CLI configured (`aws configure` or environment variables)

### Steps

1. **Save both files** (`pgcopydb-migration-instance.tf` and `user-data.sh`) in the same directory

2. **Deploy** (restricting SSH to your IP is recommended — get it from [icanhazip.com](https://icanhazip.com)):
   ```bash
   terraform init
   terraform apply \
     -var="region=us-east-1" \
     -var="vpc_id=vpc-xxx" \
     -var="subnet_id=subnet-xxx" \
     -var="your_public_ip=$(curl -s icanhazip.com)"
   ```

3. **Connect** via SSM Session Manager:
   ```bash
   aws ssm start-session --target $(terraform output -raw instance_id)
   ```
   Or via EC2 Instance Connect (browser-based SSH, no key needed — open the instance in the EC2 console and click **Connect**).

## How to Tear Down

```bash
terraform destroy \
  -var="region=us-east-1" \
  -var="vpc_id=vpc-xxx" \
  -var="subnet_id=subnet-xxx" \
  -var="your_public_ip=$(curl -s icanhazip.com)"
```

## Questions?

Visit [PlanetScale documentation](https://planetscale.com/docs) for more information.
