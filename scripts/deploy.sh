#!/usr/bin/env bash
# One command: Terraform -> inventory from outputs -> Ansible.
# Usage: scripts/deploy.sh [extra ansible-playbook args]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
ANSIBLE_DIR="$ROOT/ansible"
INVENTORY="$ANSIBLE_DIR/inventory/hosts.yml"

for tool in terraform ansible-playbook ansible-galaxy ssh; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

echo ">> terraform init/apply"
terraform -chdir="$TF_DIR" init -input=false
terraform -chdir="$TF_DIR" apply -input=false -auto-approve

echo ">> writing inventory from Terraform output"
mkdir -p "$(dirname "$INVENTORY")"
terraform -chdir="$TF_DIR" output -raw ansible_inventory > "$INVENTORY"

cd "$ANSIBLE_DIR"
ansible-galaxy collection install -r requirements.yml

# The playbook itself waits for SSH on both hosts (wait_for_connection).
VAULT_ARGS=()
if [[ -f "$ROOT/.vault_pass" ]]; then
  VAULT_ARGS=(--vault-password-file "$ROOT/.vault_pass")
elif [[ -f "$ANSIBLE_DIR/inventory/group_vars/all/vault.yml" ]]; then
  VAULT_ARGS=(--ask-vault-pass)
fi

echo ">> ansible-playbook"
ansible-playbook playbooks/site.yml ${VAULT_ARGS[@]+"${VAULT_ARGS[@]}"} "$@"

echo ">> done. App host: http://$(terraform -chdir="$TF_DIR" output -raw app_public_ip)/"
