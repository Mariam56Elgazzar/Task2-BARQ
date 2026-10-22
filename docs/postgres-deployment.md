# PostgreSQL deployment

The `postgres` Ansible role runs on the database EC2 host after Docker and
`deployment_secrets`. It expects Terraform's generated inventory to contain
`pg_data_volume_id`, the ID of a **separate attached EBS data volume**, plus
`db_private_ip` and `app_private_ip`. Terraform provisions and attaches the
encrypted data volume, and includes its ID in the generated inventory. Do not
guess a `/dev/nvme...` name or use the root disk as a substitute.

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

After the Vault password and the deployment prerequisites are available, run
the documented deployment. Check the following without displaying secrets:

```bash
sudo findmnt --mountpoint /srv/pgdata -o SOURCE,UUID,TARGET
sudo systemctl cat docker.service
sudo stat -c '%U %G %a %n' /opt/stacks/db/.env
sudo docker compose -f /opt/stacks/db/docker-compose.yml --project-directory /opt/stacks/db ps
sudo ss -ltn '( sport = :5432 )'
```

The listener must use the DB private IP, never `0.0.0.0` or its public IP.
The active site playbook deploys `postgres`, runs `db_backup`, waits for the
PostgreSQL TCP listener from the app host, and then deploys `app_stack`. From
the app host, an authenticated API create/read through Nginx can be checked
after deployment. A second Ansible run should have zero unnecessary changes;
then recreate the DB container and reboot both hosts while asserting the same
record still exists.

Local tests and static validation pass. The AWS operator reported successful
EBS-backed deployment and a clean Ansible rerun; that rerun found a completed,
checksum-valid backup. The operator also reported a passing isolated restore
check on AWS. Reboot and DB container recreation persistence, and a restore
over the live `notes` database, remain pending.

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

The local Ansible checks validate syntax and disk identification logic. The
AWS operator additionally reported a successful volume mount, private database
path, and clean rerun. A completed, checksum-valid backup was found on that
rerun and a passing temporary-database restore check; its output was not supplied
with this repository. Reboot behavior, DB container recreation persistence, and
a restore over the live `notes` database remain unverified. An archive alone
does not prove recovery.
