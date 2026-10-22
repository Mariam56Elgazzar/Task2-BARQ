#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

for tool in terraform curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL required command is unavailable: %s\n' "$tool"
    exit 1
  fi
done

if ! app_public_ip="$(terraform -chdir="$ROOT/terraform" output -raw app_public_ip)"; then
  printf '%s\n' 'FAIL could not read app_public_ip from Terraform output'
  exit 1
fi
base_url="http://$app_public_ip"
response_file="$(mktemp)"
test_note_id=""
test_title="verify-$(date -u +%Y%m%dT%H%M%SZ)-$$"
test_content="Temporary verification note from scripts/verify-app.sh"

remove_test_note() {
  local delete_status
  if [[ -n "$test_note_id" ]]; then
    if delete_status="$(curl -sS --max-time 15 -o "$response_file" -w '%{http_code}' \
      -X DELETE "$base_url/api/notes/$test_note_id") &&
      [[ "$delete_status" == "204" ]]; then
      printf '%s\n' 'PASS removed temporary verification note'
    else
      printf '%s\n' 'FAIL could not remove temporary verification note'
      failures=$((failures + 1))
    fi
  fi
}
trap 'rm -f "$response_file"' EXIT

if ready_status="$(curl -sS --max-time 10 -o "$response_file" -w '%{http_code}' \
  "$base_url/readyz")" && [[ "$ready_status" == "200" ]]; then
  printf '%s\n' 'PASS GET /readyz returned HTTP 200'
else
  printf '%s\n' 'FAIL GET /readyz did not return HTTP 200'
  failures=$((failures + 1))
fi

payload="$(printf '{"title":"%s","content":"%s"}' "$test_title" "$test_content")"
if post_status="$(curl -sS --max-time 15 -o "$response_file" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-binary "$payload" "$base_url/api/notes")" &&
  [[ "$post_status" == "201" ]]; then
  if test_note_id="$(python3 - "$response_file" "$test_title" "$test_content" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as response_file:
    note = json.load(response_file)
if note.get("title") != sys.argv[2] or note.get("content") != sys.argv[3]:
    raise SystemExit("created note response did not match the submitted note")
note_id = note.get("id")
if not isinstance(note_id, int) or note_id < 1:
    raise SystemExit("created note response did not contain a valid id")
print(note_id)
PY
  )"; then
    printf '%s\n' 'PASS POST /api/notes returned HTTP 201 with the submitted note'
  else
    printf '%s\n' 'FAIL POST /api/notes returned an invalid note response'
    failures=$((failures + 1))
  fi
else
  printf '%s\n' 'FAIL POST /api/notes did not return HTTP 201'
  failures=$((failures + 1))
fi

if [[ -n "$test_note_id" ]]; then
  if list_status="$(curl -sS --max-time 15 -o "$response_file" -w '%{http_code}' \
    "$base_url/api/notes")" &&
    [[ "$list_status" == "200" ]] &&
    python3 - "$response_file" "$test_note_id" "$test_title" "$test_content" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as response_file:
    notes = json.load(response_file)
if not isinstance(notes, list):
    raise SystemExit("notes response was not a list")
note_id = int(sys.argv[2])
if not any(
    note.get("id") == note_id
    and note.get("title") == sys.argv[3]
    and note.get("content") == sys.argv[4]
    for note in notes
):
    raise SystemExit("notes list did not contain the created verification note")
PY
  then
    printf '%s\n' 'PASS GET /api/notes returned the created note'
  else
    printf '%s\n' 'FAIL GET /api/notes did not return the created note'
    failures=$((failures + 1))
  fi
else
  printf '%s\n' 'FAIL GET /api/notes was skipped because note creation failed'
  failures=$((failures + 1))
fi

remove_test_note

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
