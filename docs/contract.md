# Interface contract (Person A <-> Person B)

| Item | Agreed value |
|---|---|
| Inventory groups / hosts | `app` -> `app1`, `db` -> `db1` |
| Host vars (from Terraform output) | `ansible_host` (public IP), `private_ip`, `ansible_user: ubuntu` |
| Global vars (from Terraform output) | `db_private_ip`, `app_private_ip` (later: `pg_data_volume_id`) |
| Static vars (`group_vars/all/main.yml`) | `db_port: 5432`, `db_name: notes`, `db_app_user: notes_app`, `backup_retention_days: 7` |
| Vault vars | `vault_pg_admin_password`, `vault_pg_app_password` |
| Network | VPC `10.20.0.0/16`, subnet `10.20.1.0/24`, app `10.20.1.10`, db `10.20.1.20` |
| Host paths | `/opt/stacks/app`, `/opt/stacks/db`, `/srv/pgdata` (data EBS), `/var/backups/postgres` |
| App container | Listens on 8000; env `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` (from `db_app_user`), `DB_PASSWORD`; endpoints `/healthz`, `/readyz`, `/api/notes` |
| Image names | App uses `app_image` as `ghcr.io/<owner>/<image>@sha256:<digest>`; Nginx and Postgres images use pinned tags |

## Open questions for Person B (from review of PR #1)

1. Dockerfile location and build context: the code imports `app.main` from the repo root.
2. Who runs `python -m app.init_db` on the DB host, with which owner role, and who applies the grants from `app/README.md`?
3. Which image tag will the `app_stack` role pull?
