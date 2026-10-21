#!/usr/bin/env bash
# Checks this machine before deploying. Exit 0 = ready, 1 = something must be fixed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
FAIL=0

pass() { printf '  [ OK ] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=1; }

echo "Preflight checks"

# 1. Tools
for tool in terraform ansible-playbook ansible-galaxy aws ssh curl; do
  if command -v "$tool" >/dev/null 2>&1; then pass "$tool installed"; else fail "$tool is not installed"; fi
done

if command -v terraform >/dev/null 2>&1; then
  read -r major minor < <(terraform version | head -n1 | sed -E 's/^Terraform v([0-9]+)\.([0-9]+).*/\1 \2/')
  if [[ "${major:-0}" =~ ^[0-9]+$ && "${minor:-0}" =~ ^[0-9]+$ ]] && { (( major > 1 )) || (( major == 1 && minor >= 5 )); }; then
    pass "terraform version ${major}.${minor} (>= 1.5 required)"
  else
    fail "terraform must be >= 1.5"
  fi
fi

# 2. Repo location (WSL: the Windows drive causes permission problems)
case "$ROOT" in
  /mnt/*) fail "repo is on the Windows drive ($ROOT); clone it under ~/ inside WSL" ;;
  *)      pass "repo is on the Linux filesystem" ;;
esac

# 3. AWS credentials
if command -v aws >/dev/null 2>&1; then
  if arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
    pass "AWS credentials valid (${arn})"
  else
    fail "AWS credentials are missing or invalid (run: aws configure)"
  fi
fi

# 4. SSH key
if [[ -f "$KEY" ]]; then
  mode="$(stat -c '%a' "$KEY")"
  if [[ "$mode" == "600" ]]; then pass "SSH private key exists with mode 600"; else fail "SSH key mode is $mode, run: chmod 600 $KEY"; fi
else
  fail "SSH private key not found at $KEY (run: ssh-keygen -t ed25519)"
fi
if [[ -f "$KEY.pub" ]]; then pass "SSH public key exists"; else fail "SSH public key not found at $KEY.pub"; fi

# 5. Terraform variables (ubuntu_ami_id is required)
TFVARS="$ROOT/terraform/terraform.tfvars"
if [[ -f "$TFVARS" ]]; then
  if grep -Eq '^[[:space:]]*ubuntu_ami_id[[:space:]]*=[[:space:]]*"ami-[0-9a-f]+"' "$TFVARS"; then
    pass "ubuntu_ami_id is set in terraform.tfvars"
  else
    fail "ubuntu_ami_id in terraform.tfvars is missing or still a placeholder"
  fi
else
  fail "terraform/terraform.tfvars not found (copy terraform.tfvars.example and set ubuntu_ami_id)"
fi

# 6. Public IP detection (used for the SSH rule when admin_cidr is empty)
if ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')" && [[ -n "$ip" ]]; then
  pass "public IP detected (${ip})"
else
  warn "could not detect public IP; set admin_cidr in terraform/terraform.tfvars"
fi

# 7. Ansible collection
if ansible-galaxy collection list 2>/dev/null | grep -q 'community.docker'; then
  pass "community.docker collection installed"
else
  warn "community.docker not installed yet (scripts/deploy.sh installs it)"
fi

# 8. Vault
VAULT="$ROOT/ansible/inventory/group_vars/all/vault.yml"
if [[ -f "$VAULT" ]]; then
  # shellcheck disable=SC2016
  if head -c 14 "$VAULT" | grep -q '^\$ANSIBLE_VAULT'; then
    pass "vault.yml is encrypted"
  else
    fail "vault.yml exists but is NOT encrypted (run: ansible-vault encrypt $VAULT)"
  fi
  if [[ -f "$ROOT/.vault_pass" ]]; then pass ".vault_pass present"; else warn ".vault_pass missing; Ansible will ask for the vault password"; fi
fi

# 9. Secrets must not be tracked by Git
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  tracked="$(git -C "$ROOT" ls-files | grep -E '(\.pem$|\.tfstate|\.vault_pass|(^|/)terraform\.tfvars$|ansible/inventory/hosts\.yml$)' || true)"
  if [[ -z "$tracked" ]]; then pass "no secrets or generated files tracked by Git"; else fail "tracked by Git (remove them): ${tracked//$'\n'/, }"; fi
fi

echo
if (( FAIL )); then echo "Preflight FAILED"; exit 1; fi
echo "Preflight OK"
