# PostgreSQL deployment

The `postgres` Ansible role runs on the database EC2 host after Docker and
`deployment_secrets`. It expects Terraform's generated inventory to contain
`pg_data_volume_id`, the ID of a **separate attached EBS data volume**, plus
`db_private_ip` and `app_private_ip`. The current Terraform configuration must
gain that volume and output before this role can run on AWS. Do not guess a
`/dev/nvme...` name or use the root disk as a substitute.

The role matches the EBS volume ID to its NVMe serial, rejects missing,
ambiguous, partitioned, or unexpectedly mounted disks, and formats only a
disk with no filesystem. It mounts the filesystem by UUID at `/srv/pgdata`.
PostgreSQL data lives in `/srv/pgdata/data`; a separate directory avoids the
`lost+found` entry that makes a new ext4 mount unsuitable as PostgreSQL's
data directory. The pinned PostgreSQL 17 Debian image uses UID/GID 999.

The database Compose project is `/opt/stacks/db`. It reads the protected
`.env` file made by `deployment_secrets`, binds PostgreSQL's port to the DB
host's private IP, and limits remote password authentication to the app
host's private IP. Administration uses a protected local Unix socket. Ansible
creates the restricted `notes_app` role, the notes table, and only the grants
needed by the API; it then authenticates as that role to read the table.

At reboot, a Docker service dependency requires `/srv/pgdata` to be mounted.
If the data volume is missing, Docker must fail to start instead of starting
the DB on the root filesystem. Normal Ansible runs do not force container
recreation.

## Verification on the actual hosts

After the data-volume output and Vault password are available, run the
documented deployment. Check the following without displaying secrets:

```bash
sudo findmnt --mountpoint /srv/pgdata -o SOURCE,UUID,TARGET
sudo systemctl cat docker.service
sudo stat -c '%U %G %a %n' /opt/stacks/db/.env
sudo docker compose -f /opt/stacks/db/docker-compose.yml --project-directory /opt/stacks/db ps
sudo ss -ltn '( sport = :5432 )'
```

The listener must use the DB private IP, never `0.0.0.0` or its public IP.
From the app host, check an authenticated API create/read through Nginx once
`app_stack` is integrated. Check a second Ansible run for zero unnecessary
changes, then recreate the DB container and reboot both hosts while asserting
the same record still exists. Those AWS checks have not yet been run.

## Troubleshooting

If Ansible stops before Compose, check that the Terraform inventory contains
the attached volume ID, that `lsblk -o NAME,SERIAL,FSTYPE,MOUNTPOINT` shows
it, and that `findmnt /srv/pgdata` reports the expected UUID. Do not format an
existing disk to make an error disappear. If Docker is stopped after reboot,
inspect `systemctl status srv-pgdata.mount docker.service` and the EBS
attachment first. If PostgreSQL is unhealthy, inspect `docker compose ps` and
container logs on the DB host. For a failed app connection, check the private
listener, security group, `pg_hba.conf`, then the role and database grants.
Do not print `.env`, decrypted Vault, or unredacted Compose configuration.

The local Ansible checks validate syntax and disk identification logic.
They do not prove AWS storage, network isolation, reboot behavior, or data
persistence. Backups and restoration are separate upcoming roles.
