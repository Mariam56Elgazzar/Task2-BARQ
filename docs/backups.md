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

From the repository root, the same operation is:

```bash
make backup
```

The explicit backup play prints a `BACKUP_ARCHIVE=notes-...dump` basename. Save
that name if you need to choose this archive for recovery; it contains no
password. Do not copy the database `.env` or decrypted Vault contents.

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
restore of deleted data proves recovery**. The second AWS Ansible run found a
completed, checksum-valid archive. The AWS operator later reported that
`make verify-restore-isolated` passed on the deployed database. Its output was
not supplied with this repository; this is a teammate-reported result. A
separate before/after confirmation of a pre-existing live note was not supplied.
The check demonstrates deleted-record recovery in a temporary database. A
restore over the live `notes` database, including app stop and restart, remains
untested.

## Check recovery without changing live notes

Run this from the deployment operator's checkout, with the generated inventory
and Vault password available:

```bash
make verify-restore-isolated
```

This takes a fresh backup of the live `notes` database, verifies its checksum,
and restores it into a uniquely named **temporary database on the existing DB
host**. It adds a marker only to that temporary database, backs it up, deletes
the marker, restores the temporary backup, and checks that the same ID and
content return. It then drops the temporary database and removes the temporary
archive. It never uses the live `notes` database as a restore target or stops
the app. The new source backup remains under the normal seven-day retention
policy, which may remove older archives. The test briefly uses additional DB
and backup disk space; leave enough free space for both copies. It holds the
backup lock throughout, so a scheduled backup cannot run at the same time.

If the check fails, it attempts to remove its temporary database and archive.
Check disk space, the data mount, database container, and selected archive.
Ansible hides the helper's output because it handles a copy of the data. If
cleanup also fails, ask the DB operator to
inspect temporary databases named `notes_restore_check_...` and remove only
the one from this failed check. The live `notes` database should be left alone.

A passing isolated check proves that a real backup can be restored and a
deleted record recovered on the deployed PostgreSQL server. It does not prove
that the live app can be stopped and resumed after rewinding its own database;
that separate, disruptive demonstration needs a disposable database or an
approved maintenance window.

## Explicit recovery

Restore rewinds the **entire notes database** to the selected backup. Notes
created or edited afterward will be lost, and notes deleted afterward will
return. Coordinate with the operator and users before running it. Normal
`make up` never invokes `restore.yml`.

After inventory and Vault access are ready, choose the basename of a completed
archive on the DB host and run from the controller:

```bash
cd ansible
ansible-playbook playbooks/restore.yml \
  --vault-password-file ../.vault_pass \
  -e restore_backup_file=notes-YYYYMMDDTHHMMSSNNNNNNNNNZ.dump
```

The playbook accepts a basename, not an arbitrary path. It verifies the
checksum, archive catalog, and data mount before touching the app. It requires
the app Compose project to exist, but can proceed if `/readyz` is already down.
It stops the app and Nginx to block writes, takes the backup job's lock, and
restores the archive in a single PostgreSQL transaction. The archive itself is
never modified. Since dumps exclude ownership and grants, Ansible reapplies the
restricted app user's schema, table, and sequence permissions. It then starts
the app and requires `/readyz` through Nginx. On failure it attempts to bring
the app back and reports the failure; inspect the failed task and database
state before retrying. A checksum check alone cannot prove data recovery.

For a live proof with a disposable marker note:

```bash
RESTORE_CONFIRM=I_UNDERSTAND make restore-demo
```

The script creates a unique note through Nginx, takes a new backup, deletes
the note, requires HTTP 404, restores that backup, and requires the **same ID
and content** to return with HTTP 200. It prints the measured elapsed seconds
and removes its marker after success. If a step fails, it leaves the marker
and archive for inspection rather than claiming recovery. Run this when other
users are not writing; it still rewinds all changes made after its backup.

Troubleshooting order: check that the selected `.dump` and `.sha256` pair are
present under `/var/backups/postgres`, then the checksum, `/srv/pgdata` mount,
healthy DB container, app grants, and `/readyz`. The backup and restore helper
share a lock; retry after a scheduled backup finishes. Do not print protected
environment files or decrypted Vault data while diagnosing a failure.
