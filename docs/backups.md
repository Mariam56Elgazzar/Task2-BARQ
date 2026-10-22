# PostgreSQL backups

The `db_backup` role is integrated into `ansible/playbooks/site.yml` and runs
after the `postgres` role on the database host. On the first deployment
it creates one backup if no completed, checksum-valid archive exists. It then
enables `notes-pg-backup.timer` for **02:30 UTC daily**. The timer has
`Persistent=true`, so a missed run is started after the host comes back.
Normal Ansible reruns do not create a new backup when one already exists.

Each run streams a PostgreSQL custom-format dump out of the container to the
database host's `/var/backups/postgres` directory. It keeps a temporary file
until `pg_restore --list` can read the archive, writes a SHA-256 sidecar, then
renames both into a completed backup. The directory is root-owned and mode
`0700`; files are created with a restrictive umask. A lock prevents overlap.
After a successful new backup, archive/checksum pairs older than seven days
are removed. Failed runs leave older good backups alone. These backups are on
the same EC2 host, so losing that host or its root disk can lose the backups;
off-host backup storage is not part of this lab.

## Use and inspect

From the Ansible controller after inventory and Vault setup:

```bash
cd ansible
ansible-playbook playbooks/backup-now.yml --vault-password-file ../.vault_pass
```

On the database host, inspect schedule and result without printing credentials:

```bash
sudo systemctl status notes-pg-backup.timer
sudo systemctl list-timers notes-pg-backup.timer
sudo journalctl -u notes-pg-backup.service --since today
sudo ls -l /var/backups/postgres/notes-*.dump*
sudo /usr/local/sbin/notes-pg-backup --has-complete
```

The last command returns status 0 when at least one checksum-valid completed
backup exists and status 1 otherwise. It does not take a new backup. To check a
specific archive, enter the protected directory as root and run
`sha256sum --check <archive>.sha256`; the checksum file contains only the
archive's basename.

If a scheduled run fails, check that `/srv/pgdata` is mounted, Docker and the
database container are healthy, and the protected database environment exists.
Read the service journal for the failing command. Partial files are removed on
failure; older completed backups remain. A successful `pg_restore --list`
and checksum show the archive is readable and unchanged, but **only a real
restore of deleted data proves recovery**. No real backup execution on AWS or
restore demonstration has been performed. End-to-end recovery remains pending;
local tests and static validation do not prove AWS backup or restore behavior.
