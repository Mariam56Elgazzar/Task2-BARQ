# Task2-BARQ

A PostgreSQL-backed notes API with a local Docker Compose development stack and
an AWS Terraform + Ansible deployment. For local setup, see
[docs/local-development.md](docs/local-development.md); for the API contract and
tests, see [app/README.md](app/README.md).

## AWS deployment runbook


- [Local container setup, verification, and troubleshooting](docs/local-development.md)
- [API endpoints, configuration, schema, and tests](app/README.md)
- [Deployment credentials and protected environment files](docs/deployment-secrets.md)
- [PostgreSQL storage, deployment, and checks](docs/postgres-deployment.md)
- [Daily PostgreSQL backups and checks](docs/backups.md)
- [Image release workflow, registry access, and troubleshooting](docs/image-release.md)

**Deployment status:** The PostgreSQL deployment and guarded backup roles are
integrated into the normal deployment playbook. The deployment order is
`postgres`, then `db_backup` on the database host, followed by a TCP readiness
check for PostgreSQL from the application host, and then `app_stack`. The
application stack is not deployed until that readiness check succeeds.

The local tests and static validation pass. No real AWS deployment or EBS mount
test has been performed; reboot persistence has not been tested; no real backup
has been executed on AWS; and no restore demonstration has been completed.
End-to-end recovery remains pending. Do not treat any of these AWS behaviors
as proven by local checks.

### Prerequisites

- Linux or WSL, with this checkout on a Linux filesystem.
- AWS credentials for the target account and permission to manage the
  Terraform resources in `eu-central-1`. Check expected AWS costs before
  provisioning.
- Terraform >= 1.5.0, AWS CLI, OpenSSH client, `ansible-core` 2.21.5 (the
  version verified for this project), and `make`.
- The repository does not pin AWS CLI, OpenSSH, or `make` versions; use
  currently supported releases compatible with your Linux/WSL distribution.
- An SSH key pair. The default private key is `~/.ssh/id_ed25519`; its public
  key must be available at the matching `.pub` path.
- The pinned Ansible collection, installed by the deployment script:
  `community.docker` 5.4.0.
- A released application image digest in GHCR and valid Ansible Vault
  credentials. See [docs/image-release.md](docs/image-release.md) and
  [docs/deployment-secrets.md](docs/deployment-secrets.md).

### Configure and deploy

1. Configure AWS credentials using your normal secure AWS credential method.
   Do not add credentials to the repository.
2. Create a local Terraform variables file from the example:

   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```

   Set `ubuntu_ami_id` to a **verified Ubuntu 24.04 AMD64 AMI ID for
   `eu-central-1`**. The example intentionally has a placeholder; do not deploy
   until it has been replaced with a verified value. Set `ssh_private_key_path`
   if your key is not `~/.ssh/id_ed25519`, and set `admin_cidr` if you do not
   want Terraform to detect the current public IP for SSH access.
3. Use the encrypted `ansible/inventory/group_vars/all/vault.yml` supplied for
   this project and obtain its Vault password through the agreed secure
   channel. Either allow `scripts/deploy.sh` to prompt for it or store it in
   the ignored repository-root `.vault_pass`, restricted to your account
   (`chmod 600 .vault_pass`). Do not create or share Vault passwords in Git,
   issues, logs, or command arguments. See
   [docs/deployment-secrets.md](docs/deployment-secrets.md) for the file
   variables and handling requirements.
4. After the release workflow succeeds, take the exact `sha256` digest from
   its job summary and set `app_stack_image` in
   `ansible/roles/app_stack/defaults/main.yml` to the matching
   `ghcr.io/<owner>/<image>@sha256:<digest>` reference. Do not substitute a
   tag or guess a digest.
5. Review the Terraform configuration and expected costs without applying it.
   On a clean clone, initialize, validate, and plan in this order:

   ```bash
   terraform -chdir=terraform init
   terraform -chdir=terraform validate
   terraform -chdir=terraform plan
   ```

   The active Ansible playbook installs Docker, renders protected environment
   files, deploys PostgreSQL and its backup timer, waits for PostgreSQL from
   the app host, and only then deploys the application stack. The PostgreSQL
   role mounts the dedicated EBS data volume.
6. To provision and configure after reviewing the plan:

   ```bash
   make up
   ```

   `make up` runs `scripts/deploy.sh`: Terraform init/apply with automatic
   approval, writes the generated inventory, installs the pinned Ansible
   collection, then runs the playbook. It can create or change AWS resources
   and incur charges.
7. When the database and app are deployed, run the verification checks:

   ```bash
   make verify-security
   make verify-app
   make verify-idempotency
   # Or run all three in sequence:
   make verify
   ```

   `verify-app` writes a uniquely named temporary note through the API and
   attempts to delete it. `verify-idempotency` requires an unchanged Terraform
   plan and asks before it runs Ansible. These checks have not been run against
   AWS.
8. When finished, remove the deployment:

   ```bash
   make down
   ```

   This runs `terraform destroy`. Confirm in AWS that the project resources
   were removed; do not assume cleanup succeeded just because the command
   returned.

## Why the application image is pinned by digest

A tag such as `v1.0.0` is a human-readable name and can be moved to different
image contents. A `sha256` digest identifies exact image content. Deploying the
release workflow's digest makes the application image reference reproducible
and avoids silently pulling different content under a reused tag. The release
workflow's digest must come from a successful publication; the workflow's
authenticated pull check does not by itself prove anonymous GHCR access.

## App-to-database troubleshooting order

Follow this order and use the actual private IP and credentials from Terraform
outputs and the protected deployment environment; do not put secrets in
diagnostic output:

1. **Security group:** confirm the DB security group permits TCP 5432 from the
   app security group, not from the public internet.
2. **Private IP binding:** confirm `db_host` resolves to the database host's
   private IP and PostgreSQL is listening on the interface reachable from the
   app host, not only on loopback.
3. **Port reachability:** from the app host, check TCP 5432 to `db_host`.
4. **Container health:** inspect the DB container's health and logs without
   exposing environment values. The app container health check is HTTP
   `/readyz`; Nginx waits for the app container to be healthy.
5. **Credentials:** verify the Vault variable names and that the deployed app
   `.env` matches the database role configuration. Changing Vault alone does
   not rotate a password already stored in PostgreSQL.

## Known limitations

- The AWS API currently serves HTTP on public port 80; TLS and end-user
  authentication are not configured. Treat notes as non-sensitive demo data.
- The app and DB instances are in a public subnet and receive public addresses.
  The security groups restrict app ingress to HTTP and admin SSH, and DB
  ingress to PostgreSQL from the app security group plus admin SSH. Verify the
  deployed rules rather than relying only on this description.
- PostgreSQL and `db_backup` are integrated into the active playbook, and
  Terraform provisions and attaches a dedicated EBS data volume. No real AWS
  deployment, EBS mount test, reboot persistence test, or backup execution on
  AWS has been performed. No restore demonstration is complete, and end-to-end
  recovery remains pending.
- Ansible Vault protects credentials at rest in the repository; the generated
  host `.env` files are root-owned and mode `0600`. The API container needs
  those credentials to connect to PostgreSQL.
- `make up` uses Terraform apply and can incur AWS charges. `make down` destroys
  managed resources; it must not be used as a substitute for an independently
  reviewed cleanup plan.

## Other project guides

- [Local container setup, verification, and troubleshooting](docs/local-development.md)
- [API endpoints, configuration, schema, and tests](app/README.md)
- [Deployment credentials and protected environment files](docs/deployment-secrets.md)
- [Infrastructure and deployment architecture](docs/architecture.md)
- [PostgreSQL storage, deployment, and checks](docs/postgres-deployment.md)
- [PostgreSQL backups, schedule, verification, and restore](docs/backups.md)
- [Application contract and security expectations](docs/contract.md)
- [Image release workflow and registry access](docs/image-release.md)
