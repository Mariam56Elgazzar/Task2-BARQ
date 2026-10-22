#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="$ROOT/ansible"

if [[ ! -f "$ANSIBLE_DIR/inventory/hosts.yml" ]]; then
  echo 'Generated Ansible inventory is missing. Run deployment first.' >&2
  exit 1
fi

vault_args=()
if [[ -f "$ROOT/.vault_pass" ]]; then
  vault_args=(--vault-password-file "$ROOT/.vault_pass")
else
  vault_args=(--ask-vault-pass)
fi

cd "$ANSIBLE_DIR"
ansible-playbook playbooks/backup-now.yml "${vault_args[@]}"
