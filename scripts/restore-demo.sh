#!/usr/bin/env bash
# Rewinds the entire notes database to a fresh backup; never run as normal deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="$ROOT/ansible"
start_time=$SECONDS

if [[ "${RESTORE_CONFIRM:-}" != I_UNDERSTAND ]]; then
  echo 'This demo restores the whole notes database. Set RESTORE_CONFIRM=I_UNDERSTAND to continue.' >&2
  exit 2
fi
for tool in terraform ansible-playbook curl python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
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

app_ip="$(terraform -chdir="$ROOT/terraform" output -raw app_public_ip)"
base_url="http://$app_ip"
response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT
title="restore-demo-$(date -u +%Y%m%dT%H%M%SZ)-$$"
content='Temporary marker for a real backup and restore demonstration'
payload="$(python3 - "$title" "$content" <<'PY'
import json
import sys
print(json.dumps({'title': sys.argv[1], 'content': sys.argv[2]}))
PY
)"

echo '1/5 Create a unique note through Nginx.'
status="$(curl -sS --max-time 15 -o "$response_file" -w '%{http_code}' \
  -H 'Content-Type: application/json' --data-binary "$payload" "$base_url/api/notes")"
[[ "$status" == 201 ]] || { echo "Create failed (HTTP $status)." >&2; exit 1; }
note_id="$(python3 - "$response_file" "$title" "$content" <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as response:
    note = json.load(response)
if note.get('title') != sys.argv[2] or note.get('content') != sys.argv[3]:
    raise SystemExit('Created note did not match the marker')
note_id = note.get('id')
if not isinstance(note_id, int) or note_id < 1:
    raise SystemExit('Created note has no valid id')
print(note_id)
PY
)"
echo "Created marker note $note_id."

echo '2/5 Take a new verified backup.'
if ! backup_output="$(cd "$ANSIBLE_DIR" && ansible-playbook playbooks/backup-now.yml "${vault_args[@]}")"; then
  printf '%s\n' "$backup_output"
  echo 'Backup failed; the marker remains in the live database.' >&2
  exit 1
fi
archive="$(printf '%s\n' "$backup_output" | sed -n 's/.*BACKUP_ARCHIVE=\(notes-[0-9]\{8\}T[0-9]\{15\}Z\.dump\).*/\1/p' | tail -n 1)"
[[ "$archive" =~ ^notes-[0-9]{8}T[0-9]{15}Z\.dump$ ]] || {
  echo 'Backup finished without a recognized archive name; no deletion was made.' >&2
  exit 1
}
echo "Verified backup: $archive"

echo '3/5 Delete the marker and prove it is absent.'
status="$(curl -sS --max-time 15 -o "$response_file" -w '%{http_code}' \
  -X DELETE "$base_url/api/notes/$note_id")"
[[ "$status" == 204 ]] || { echo "Delete failed (HTTP $status)." >&2; exit 1; }
status="$(curl -sS --max-time 15 -o "$response_file" -w '%{http_code}' \
  "$base_url/api/notes/$note_id")"
[[ "$status" == 404 ]] || { echo "Marker is not absent (HTTP $status)." >&2; exit 1; }
echo "Confirmed note $note_id is missing (HTTP 404)."

echo '4/5 Restore the selected backup and recover the app.'
(cd "$ANSIBLE_DIR" && ansible-playbook playbooks/restore.yml "${vault_args[@]}" \
  -e "restore_backup_file=$archive")

echo '5/5 Prove the same note returned through Nginx.'
status="$(curl -sS --max-time 15 -o "$response_file" -w '%{http_code}' \
  "$base_url/api/notes/$note_id")"
[[ "$status" == 200 ]] || { echo "Restored marker is unavailable (HTTP $status)." >&2; exit 1; }
python3 - "$response_file" "$note_id" "$title" "$content" <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as response:
    note = json.load(response)
if note.get('id') != int(sys.argv[2]) or note.get('title') != sys.argv[3] or note.get('content') != sys.argv[4]:
    raise SystemExit('Restored marker does not match the backed-up note')
PY
echo "PASS: deleted note $note_id returned from backup $archive in $((SECONDS - start_time)) seconds."

# Leave the demonstration database without the temporary marker.
status="$(curl -sS --max-time 15 -o "$response_file" -w '%{http_code}' \
  -X DELETE "$base_url/api/notes/$note_id")"
[[ "$status" == 204 ]] || echo 'Note: remove the temporary marker manually.' >&2
