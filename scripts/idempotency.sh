#!/usr/bin/env bash
# Run AFTER `make up`. Checks that a second Terraform plan and a second Ansible run change nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
ANSIBLE_DIR="$ROOT/ansible"
LOG_TF="$(mktemp)"
LOG_AN="$(mktemp)"
trap 'rm -f "$LOG_TF" "$LOG_AN"' EXIT
FAIL=0

[[ -f "$ANSIBLE_DIR/inventory/hosts.yml" ]] || { echo "No inventory found. Run 'make up' first." >&2; exit 1; }

echo ">> 1/2 terraform plan (expects: no changes)"
terraform -chdir="$TF_DIR" plan -input=false -detailed-exitcode >"$LOG_TF" 2>&1
case $? in
  0) echo "  [ OK ] Terraform: no changes" ;;
  2) echo "  [FAIL] Terraform wants to change resources (did your public IP change?)"; tail -n 40 "$LOG_TF"; FAIL=1 ;;
  *) echo "  [FAIL] terraform plan failed"; tail -n 40 "$LOG_TF"; FAIL=1 ;;
esac

echo ">> 2/2 ansible-playbook (expects: changed=0 on every host)"
cd "$ANSIBLE_DIR" || exit 1
VAULT_ARGS=()
if [[ -f "$ROOT/.vault_pass" ]]; then
  VAULT_ARGS=(--vault-password-file "$ROOT/.vault_pass")
elif [[ -f inventory/group_vars/all/vault.yml ]]; then
  VAULT_ARGS=(--ask-vault-pass)
fi
ANSIBLE_NOCOLOR=1 ansible-playbook playbooks/site.yml ${VAULT_ARGS[@]+"${VAULT_ARGS[@]}"} 2>&1 | tee "$LOG_AN"
an_rc=${PIPESTATUS[0]}

if (( an_rc != 0 )); then
  echo "  [FAIL] ansible-playbook exited with code $an_rc"; FAIL=1
else
  recap="$(grep -E '^[A-Za-z0-9_.-]+[[:space:]]*:[[:space:]]+ok=' "$LOG_AN" || true)"
  if [[ -z "$recap" ]]; then
    echo "  [FAIL] no PLAY RECAP found in Ansible output"; FAIL=1
  else
    while IFS= read -r line; do
      host="${line%%[[:space:]]*}"
      changed="$(sed -E 's/.*changed=([0-9]+).*/\1/' <<<"$line")"
      if [[ "$changed" == "0" ]]; then
        echo "  [ OK ] $host: changed=0"
      else
        echo "  [FAIL] $host: changed=$changed (a task is not idempotent)"; FAIL=1
      fi
    done <<<"$recap"
  fi
fi

echo
if (( FAIL )); then echo "Idempotency check FAILED"; exit 1; fi
echo "Idempotency check OK"
