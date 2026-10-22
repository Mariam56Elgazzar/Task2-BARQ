# Interface contract (Person A <-> Person B)

This contract distinguishes active code from the database and backup work that
is still pending.

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
| Active playbook roles | `docker`, then `deployment_secrets`, then `app_stack`; `deployment_secrets` runs before `app_stack` |
| Planned Person B roles | `postgres`, then `db_backup` on `db`, before `app_stack`; both plays remain commented out in `ansible/playbooks/site.yml` |

The Terraform-generated inventory template is
`terraform/templates/inventory.yml.tftpl`. The `db_host` alias is declared in
`ansible/inventory/group_vars/all/main.yml`; the app Compose template and
`app_stack` wait task both use `db_host`.

**TODO(person-b):** confirm whether the final database role is named `postgres`
and backup role `db_backup`, or update the commented plays and this contract to
the agreed names before enabling them.

**TODO(person-b):** define and verify who initializes the schema and grants
`notes_app` permissions. The repository contains the schema and SQL behavior
for the API, but the database deployment role is not yet active.

See [docs/deployment-secrets.md](deployment-secrets.md) for Vault handling and
protected environment-file requirements.
