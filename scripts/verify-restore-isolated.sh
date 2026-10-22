#!/usr/bin/env bash
# Test real backup recovery without changing the live notes database.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="$ROOT/ansible"

command -v ansible-playbook >/dev/null || {
  echo 'Missing required tool: ansible-playbook' >&2
  exit 1
}
[[ -f "$ANSIBLE_DIR/inventory/hosts.yml" ]] || {
  echo 'Generated Ansible inventory is missing. Run deployment first.' >&2
  exit 1
}

vault_args=()
if [[ -f "$ROOT/.vault_pass" ]]; then
  vault_args=(--vault-password-file "$ROOT/.vault_pass")
else
  vault_args=(--ask-vault-pass)
fi

# A fresh backup reads the live DB but does not alter its records. The backup
# helper applies the project's usual archive retention policy.
echo 'Taking a fresh backup of the current notes database.'
if ! backup_output="$(cd "$ANSIBLE_DIR" && ansible-playbook playbooks/backup-now.yml "${vault_args[@]}")"; then
  printf '%s\n' "$backup_output"
  echo 'Backup failed; the live notes database was not restored.' >&2
  exit 1
fi
archive="$(printf '%s\n' "$backup_output" | sed -n 's/.*BACKUP_ARCHIVE=\(notes-[0-9]\{8\}T[0-9]\{15\}Z\.dump\).*/\1/p' | tail -n 1)"
[[ "$archive" =~ ^notes-[0-9]{8}T[0-9]{15}Z\.dump$ ]] || {
  echo 'Backup finished without a recognized archive name.' >&2
  exit 1
}

echo "Checking recovery from $archive in a temporary database."
(cd "$ANSIBLE_DIR" && ansible-playbook playbooks/verify-restore-isolated.yml \
  "${vault_args[@]}" -e "restore_backup_file=$archive")
