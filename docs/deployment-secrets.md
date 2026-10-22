# Deployment credentials

The two database passwords live in the encrypted
`ansible/inventory/group_vars/all/vault.yml`. Ansible loads this file alongside
the ordinary variables in the same inventory directory. The passwords are
different: PostgreSQL's administrator uses `vault_pg_admin_password`, while the
API uses the restricted `notes_app` role and `vault_pg_app_password`.

## Prepare the controller

Run Ansible from Linux or WSL with the checkout on a Linux filesystem. Install
`ansible-core` (2.21.5 was verified) and the pinned collection:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

Keep the Vault password outside Git. The deployment script uses an ignored
`.vault_pass` at the repository root when present, and otherwise prompts for
the password. Give the deployment operator this password through a secure
channel; do not add it to the repository, a PR, an issue, a command argument,
or a log. Restrict the password file to the operator (`chmod 600 .vault_pass`
on Linux). The encrypted Vault file alone is not enough to deploy.

To edit credentials, use `ansible-vault edit` with the password file or an
interactive prompt. Use only distinct passwords of at least 32 characters from
letters, digits, `_`, and `-`; these characters are safe in Compose environment
files. Never use `ansible-vault view` in a shared terminal or captured log.

## What Ansible writes

After Docker installation, the `deployment_secrets` role writes
`/opt/stacks/db/.env` on the database host and `/opt/stacks/app/.env` on the
application host. Each directory is root owned with mode `0750`; each file is
root owned with mode `0600`. The database file supplies PostgreSQL's initial
administrator password and the app role password. The application file supplies
the app role password and the database host's private IP from Terraform's
generated inventory. Credential checks and template tasks use `no_log`, and
templates disable Ansible diffs.

Check permissions without showing values:

```bash
sudo stat -c '%U %G %a %n' /opt/stacks/db/.env
sudo stat -c '%U %G %a %n' /opt/stacks/app/.env
```

Run the relevant command only on the host with that stack. Do not paste a
rendered environment file or unredacted Compose output into a ticket. If Vault
decryption fails, check that the operator has the matching password. If a
template reports a missing variable, regenerate the inventory from Terraform
outputs and check `db_private_ip` and the two Vault variable names.

Changing a Vault password value and rerunning Ansible does **not** rotate a
password already stored in a persistent PostgreSQL database. Rotate the
database role explicitly, then update Vault and redeploy the protected files
and containers as one coordinated operation. Likewise, changing
`POSTGRES_PASSWORD` does not reinitialize an existing PostgreSQL data volume.

The role and Vault were checked with a local, disposable Ansible inventory:
decryption succeeded; both files contained the expected variables and private
address; root ownership and mode `0600` were asserted; a second run reported
zero changes. This is a local check, not an AWS deployment or database login.
