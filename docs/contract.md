# Interface contract (Person A <-> Person B)

This contract describes the active application, database, and backup
integration, and distinguishes implemented configuration from AWS validation
that is still pending.

| Item | Current code / agreed contract |
|---|---|
| Inventory groups / hosts | `app` -> `app1`, `db` -> `db1` |
| Per-host inventory vars | `ansible_host` is the public IP; `private_ip` is the host private IP |
| Global inventory vars | `ansible_user: ubuntu`, `ansible_ssh_private_key_file`, `app_private_ip`, `db_private_ip` |
| Shared DB vars (`ansible/inventory/group_vars/all/main.yml`) | `db_host: "{{ db_private_ip }}"`, `db_port: 5432`, `db_name: notes`, `db_app_user: notes_app`, `backup_retention_days: 7` |
| Vault vars | `vault_pg_admin_password`, `vault_pg_app_password` in encrypted `ansible/inventory/group_vars/all/vault.yml` |
| Network | VPC `10.20.0.0/16`, public subnet `10.20.1.0/24`, app private IP `10.20.1.10`, DB private IP `10.20.1.20` |
| Stack paths | App `/opt/stacks/app`; DB `/opt/stacks/db` |
| App environment | `/opt/stacks/app/.env`: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`; `DB_HOST` uses `db_host` |
| DB environment | `/opt/stacks/db/.env`; values are rendered by `deployment_secrets` |
| App stack | `app_stack_image` must be `ghcr.io/<owner>/<image>@sha256:<digest>`; Compose uses Nginx on host port 80 and the app on internal port 8000 |
| API endpoints | `/healthz`, `/readyz`, `/api/notes`, `/api/notes/{note_id}` |
| Active playbook order | `docker`, `deployment_secrets`, `postgres`, `db_backup`, PostgreSQL TCP readiness check from `app`, then `app_stack` |

The Terraform-generated inventory template is
`terraform/templates/inventory.yml.tftpl`. The `db_host` alias is declared in
`ansible/inventory/group_vars/all/main.yml`; the app Compose template and
`app_stack` use `db_host`. Terraform provisions and attaches the dedicated
encrypted EBS data volume, and passes its ID through the generated inventory
for the `postgres` role.

The database and backup roles are integrated in `ansible/playbooks/site.yml`.
The app stack runs only after the app host's PostgreSQL readiness check
succeeds. Local tests and static validation pass. The AWS operator reported a
successful EBS-backed deployment, a clean rerun, and a passing isolated restore
check on AWS. The restore output was not supplied with this repository. Reboot
and DB container recreation persistence, and a restore over the live `notes`
database, remain pending. These are outstanding environment checks, not missing
role integrations.

See [docs/deployment-secrets.md](deployment-secrets.md) for Vault handling and
protected environment-file requirements.
