# Task2-BARQ

A PostgreSQL-backed notes API with a local Docker Compose development stack and
an AWS Terraform + Ansible deployment. For local setup, see
[docs/local-development.md](docs/local-development.md); for the API contract and
tests, see [app/README.md](app/README.md).

## AWS deployment runbook

> **Deployment status:** the `postgres` and `db_backup` plays are still
> placeholders in `ansible/playbooks/site.yml`. The app deployment is not a
> complete end-to-end AWS deployment until the database role is implemented and
> enabled. Do not treat a successful Terraform run or app play as proof that
> the database is deployed.

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
5. Confirm that the `postgres` role is implemented and that its play is enabled
   in `ansible/playbooks/site.yml`. The playbook currently has that database
   play and the `db_backup` play commented out; provisioning must not be
   represented as complete until those required roles are ready.
6. Review the Terraform plan and expected costs:

   ```bash
   terraform -chdir=terraform plan
   ```

   If the plan is expected, provision and configure:

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
   AWS by this documentation change.
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
- The DB deployment, EBS data mounting, reboot recovery, and backup/restore
  implementation are not complete in the current active Ansible playbook.
- Ansible Vault protects credentials at rest in the repository; the generated
  host `.env` files are root-owned and mode `0600`. The API container needs
  those credentials to connect to PostgreSQL.
- `make up` uses Terraform apply and can incur AWS charges. `make down` destroys
  managed resources; it must not be used as a substitute for an independently
  reviewed cleanup plan.

## Person B — pending documentation

- **TODO(person-b): Backup/restore:** document the implemented backup schedule,
  retention, restore procedure, and tested evidence.
- **TODO(person-b): Reboot recovery:** document the verified recovery behavior
  and test procedure.
- **TODO(person-b): EBS mounting:** document the implemented data volume,
  filesystem/mount configuration, and persistence checks.
- **TODO(person-b): Reused-code note:** identify any reused code and document
  its source and applicable license.

## Other project guides

- [Architecture and network design](docs/architecture.md)
- [Person A/Person B interface contract](docs/contract.md)
- [Infrastructure details](docs/infra.md)
- [Deployment credentials](docs/deployment-secrets.md)
- [Image releases](docs/image-release.md)
- [Local container development](docs/local-development.md)
