# Infrastructure (Person A)

## Architecture

- One VPC `10.20.0.0/16`, one public subnet `10.20.1.0/24`, internet gateway, route table.
- App host `10.20.1.10`: only port 80 public. SSH only from `admin_cidr`.
- DB host `10.20.1.20`: port 5432 reachable only from the app security group. SSH only from `admin_cidr`.
- Terraform builds AWS. Ansible installs Docker and deploys containers. Nothing else is installed on the hosts by hand.

## Prerequisites

- AWS credentials (`aws configure`), SSH key at `~/.ssh/id_ed25519` (+ `.pub`).
- Terraform >= 1.5, ansible-core, ssh. Run from WSL/Linux, repo cloned under `~/`.

## Deploy

1. Copy the example variables file. The real `terraform.tfvars` is git-ignored and must never be committed:

```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

2. Edit `terraform/terraform.tfvars` and replace the placeholder `ami-REPLACE_WITH_REGION_SPECIFIC_AMI` in `ubuntu_ami_id` with a verified Canonical Ubuntu 24.04 AMD64 AMI in your configured region. The AMI must match the AWS region and the architecture (x86_64). One way to find the newest one:

```bash
   aws ec2 describe-images --owners 099720109477 --region eu-central-1 \
     --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
     --query 'sort_by(Images,&CreationDate)[-1].[ImageId,Name,Architecture]' --output text
```

   `ubuntu_ami_id` is required: without it Terraform cannot plan. The AMI stays pinned until you change it, and changing it later can replace the instances, so review the plan first.

3. Optional: set `admin_cidr` (SSH source) and `region` in the same file. If `admin_cidr` is empty, Terraform detects your current public IP.

4. Deploy:

```bash
   make up        # or scripts/deploy.sh
```

If your public IP changes, the next `terraform plan` will show the SSH rule changing; that is expected.

## Cleanup

```bash
make down      # terraform destroy
```

Check the AWS console afterwards (instances, volumes, key pairs, security groups).
