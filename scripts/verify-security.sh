#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

for tool in terraform nc aws; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL required command is unavailable: %s\n' "$tool"
    exit 1
  fi
done

if ! app_public_ip="$(terraform -chdir="$ROOT/terraform" output -raw app_public_ip)"; then
  printf '%s\n' 'FAIL could not read app_public_ip from Terraform output'
  exit 1
fi
if ! db_public_ip="$(terraform -chdir="$ROOT/terraform" output -raw db_public_ip)"; then
  printf '%s\n' 'FAIL could not read db_public_ip from Terraform output'
  exit 1
fi

check_reachable() {
  local host="$1"
  local port="$2"
  local expected="$3"
  local label="$4"
  local reachable=false

  if nc -z -w 3 "$host" "$port" >/dev/null 2>&1; then
    reachable=true
  fi

  if [[ "$reachable" == "$expected" ]]; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    failures=$((failures + 1))
  fi
}

check_reachable "$app_public_ip" 80 true "app public port 80 is reachable"
check_reachable "$app_public_ip" 8000 false "app public port 8000 is not reachable"
check_reachable "$app_public_ip" 5432 false "app public port 5432 is not reachable"
check_reachable "$db_public_ip" 5432 false "database public port 5432 is not reachable"

app_sg_ids=""
db_sg_ids=""
if app_sg_ids="$(aws ec2 describe-instances \
  --filters "Name=ip-address,Values=$app_public_ip" \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' \
  --output text)" &&
  db_sg_ids="$(aws ec2 describe-instances \
    --filters "Name=ip-address,Values=$db_public_ip" \
    --query 'Reservations[].Instances[].SecurityGroups[].GroupId' \
    --output text)"; then
  read -r -a app_sg_array <<<"$app_sg_ids"
  read -r -a db_sg_array <<<"$db_sg_ids"
  if [[ "$app_sg_ids" != "None" && "$db_sg_ids" != "None" &&
    "${#app_sg_array[@]}" -eq 1 && "${#db_sg_array[@]}" -eq 1 ]]; then
    printf '%s\n' 'Project security-group ingress rules:'
    if aws ec2 describe-security-groups \
      --group-ids "${app_sg_array[0]}" "${db_sg_array[0]}" \
      --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Ingress:IpPermissions}' \
      --output json; then
      printf '%s\n' 'PASS retrieved ingress rules for app and database security groups'
    else
      printf '%s\n' 'FAIL could not retrieve project security-group ingress rules'
      failures=$((failures + 1))
    fi
  else
    printf '%s\n' 'FAIL could not identify exactly one security group per project instance'
    failures=$((failures + 1))
  fi
else
  printf '%s\n' 'FAIL could not identify project instance security groups'
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
