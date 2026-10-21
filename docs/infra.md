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

```bash
make up        # or scripts/deploy.sh
```

Terraform detects your public IP for SSH automatically (`admin_cidr`). If your IP changes, the next `terraform plan` will show the SSH rule changing; that is expected.

## Cleanup

```bash
make down      # terraform destroy
```

Check the AWS console afterwards (instances, volumes, key pairs, security groups).
