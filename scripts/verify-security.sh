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
if ! admin_cidr="$(terraform -chdir="$ROOT/terraform" output -raw admin_cidr)"; then
  printf '%s\n' 'FAIL could not read admin_cidr from Terraform output'
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

discover_instance_sg_id() {
  local public_ip="$1"
  local instances_json

  instances_json="$(aws ec2 describe-instances \
    --filters "Name=ip-address,Values=$public_ip" \
    --query 'Reservations[].Instances[].SecurityGroups[].GroupId' \
    --output json)" || return 1

  python3 -c '
import json
import sys

group_ids = json.load(sys.stdin)
if not isinstance(group_ids, list) or len(group_ids) != 1:
    raise SystemExit(1)
group_id = group_ids[0]
if not isinstance(group_id, str) or not group_id:
    raise SystemExit(1)
print(group_id)
' <<<"$instances_json"
}

app_sg_id=""
db_sg_id=""
if app_sg_id="$(discover_instance_sg_id "$app_public_ip")"; then
  :
else
  printf '%s\n' 'FAIL could not identify exactly one app security group'
  failures=$((failures + 1))
fi
if db_sg_id="$(discover_instance_sg_id "$db_public_ip")"; then
  :
else
  printf '%s\n' 'FAIL could not identify exactly one database security group'
  failures=$((failures + 1))
fi

if [[ -n "$app_sg_id" && -n "$db_sg_id" ]]; then
  security_group_rules_json=""
  if security_group_rules_json="$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$app_sg_id,$db_sg_id" \
    --output json)"; then
    if SECURITY_GROUP_RULES_JSON="$security_group_rules_json" \
      python3 - "$app_sg_id" "$db_sg_id" "$admin_cidr" <<'PY'
import json
import os
import sys

app_group_id, db_group_id, admin_cidr = sys.argv[1:]

checks = [
    ("app TCP/80 from 0.0.0.0/0", app_group_id, 80, "cidr", "0.0.0.0/0"),
    ("app TCP/22 from admin_cidr", app_group_id, 22, "cidr", admin_cidr),
    ("database TCP/5432 from app security group", db_group_id, 5432, "group", app_group_id),
    ("database TCP/22 from admin_cidr", db_group_id, 22, "cidr", admin_cidr),
]


def source_for(rule):
    sources = []
    if "CidrIpv4" in rule:
        sources.append(("cidr", rule["CidrIpv4"]))
    if "CidrIpv6" in rule:
        sources.append(("ipv6", rule["CidrIpv6"]))
    if "PrefixListId" in rule:
        sources.append(("prefix", rule["PrefixListId"]))
    referenced_group = rule.get("ReferencedGroupInfo")
    if isinstance(referenced_group, dict) and "GroupId" in referenced_group:
        sources.append(("group", referenced_group["GroupId"]))
    return sources


def applies_to_port(rule, port):
    if rule.get("IsEgress") is not False:
        return False
    protocol = rule.get("IpProtocol")
    if protocol == "-1":
        return True
    if protocol not in ("tcp", "6"):
        return False
    try:
        start = int(rule["FromPort"])
        end = int(rule["ToPort"])
    except (KeyError, TypeError, ValueError):
        return False
    return start <= port <= end


try:
    response = json.loads(os.environ["SECURITY_GROUP_RULES_JSON"])
    rules = response["SecurityGroupRules"]
    if not isinstance(rules, list):
        raise ValueError("SecurityGroupRules is not a list")
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    for label, *_ in checks:
        print(f"FAIL {label}: could not parse security-group rules")
    raise SystemExit(len(checks))

failures = 0
for label, group_id, port, expected_source_type, expected_source in checks:
    candidates = [
        rule
        for rule in rules
        if rule.get("GroupId") == group_id and applies_to_port(rule, port)
    ]

    valid = (
        len(candidates) == 1
        and candidates[0].get("IpProtocol") == "tcp"
        and candidates[0].get("FromPort") == port
        and candidates[0].get("ToPort") == port
        and source_for(candidates[0]) == [(expected_source_type, expected_source)]
    )
    if valid:
        print(f"PASS {label}")
    else:
        print(f"FAIL {label}: expected exactly one rule with the specified source")
        failures += 1

raise SystemExit(failures)
PY
    then
      :
    else
      rule_failures=$?
      failures=$((failures + rule_failures))
    fi
  else
    printf '%s\n' 'FAIL could not retrieve project security-group ingress rules'
    failures=$((failures + 4))
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
