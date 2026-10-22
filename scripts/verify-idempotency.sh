#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

for tool in terraform ansible-playbook python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL required command is unavailable: %s\n' "$tool"
    exit 1
  fi
done

if terraform -chdir="$ROOT/terraform" plan -input=false -detailed-exitcode; then
  printf '%s\n' 'PASS Terraform plan reports no changes'
else
  plan_status=$?
  if [[ "$plan_status" -eq 2 ]]; then
    printf '%s\n' 'FAIL Terraform plan reports changes'
  else
    printf 'FAIL Terraform plan failed with exit status %s\n' "$plan_status"
  fi
  exit 1
fi

if [[ ! -t 0 ]]; then
  printf '%s\n' 'FAIL interactive confirmation is required before running Ansible'
  exit 1
fi

read -r -p "Run ansible-playbook on the configured inventory now? Type 'yes' to confirm: " confirmation
if [[ "$confirmation" != "yes" ]]; then
  printf '%s\n' 'FAIL Ansible run was not confirmed; playbook was not run'
  exit 1
fi

ansible_log="$(mktemp)"
trap 'rm -f "$ansible_log"' EXIT
if [[ -f "$ROOT/.vault_pass" ]]; then
  vault_args=(--vault-password-file "$ROOT/.vault_pass")
else
  vault_args=(--ask-vault-pass)
fi

if ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" ansible-playbook \
  "$ROOT/ansible/playbooks/site.yml" "${vault_args[@]}" 2>&1 | tee "$ansible_log"; then
  :
else
  printf '%s\n' 'FAIL ansible-playbook returned a non-zero status'
  exit 1
fi

if python3 - "$ansible_log" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as log_file:
    lines = log_file.readlines()
try:
    recap_index = next(index for index, line in enumerate(lines) if line.startswith("PLAY RECAP"))
except StopIteration:
    raise SystemExit("PLAY RECAP was not found")

recaps = []
for line in lines[recap_index + 1:]:
    match = re.match(r"^\S+\s*:\s*(.*)$", line)
    if not match:
        continue
    counts = dict(re.findall(r"(changed|failed|unreachable)=(\d+)", match.group(1)))
    if len(counts) != 3:
        raise SystemExit(f"recap is missing a required count: {line.rstrip()}")
    recaps.append((line.split(":", 1)[0].strip(), counts))

if not recaps:
    raise SystemExit("no host recap lines were found")

problems = [
    f"{host}: {name}={counts[name]}"
    for host, counts in recaps
    for name in ("changed", "failed", "unreachable")
    if int(counts[name]) > 0
]
if problems:
    raise SystemExit("; ".join(problems))
PY
then
  printf '%s\n' 'PASS Ansible recap has changed=0, failed=0, and unreachable=0 for every host'
else
  printf '%s\n' 'FAIL Ansible recap does not satisfy idempotency requirements'
  exit 1
fi
