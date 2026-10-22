.PHONY: help up down ssh-app ssh-db backup restore-demo verify-restore-isolated verify-security verify-app verify-idempotency verify

help: ## List targets
	@grep -E "^[a-z-]+:.*##" $(MAKEFILE_LIST) | sed "s/:.*## /: /"

up: ## Provision AWS and configure both hosts
	scripts/deploy.sh

down: ## Destroy all AWS resources
	scripts/destroy.sh

ssh-app: ## SSH to the app host
	ssh -o StrictHostKeyChecking=no -i $$(terraform -chdir=terraform output -raw ssh_private_key_path) $$(terraform -chdir=terraform output -raw ssh_user)@$$(terraform -chdir=terraform output -raw app_public_ip)

ssh-db: ## SSH to the database host
	ssh -o StrictHostKeyChecking=no -i $$(terraform -chdir=terraform output -raw ssh_private_key_path) $$(terraform -chdir=terraform output -raw ssh_user)@$$(terraform -chdir=terraform output -raw db_public_ip)

backup: ## Take an explicit PostgreSQL backup
	scripts/backup-now.sh

restore-demo: ## Prove insert, backup, delete, and restore (RESTORE_CONFIRM=I_UNDERSTAND)
	scripts/restore-demo.sh

verify-restore-isolated: ## Prove backup recovery in a temporary database without changing live notes
	scripts/verify-restore-isolated.sh

verify-security: ## Check public port reachability and print project security-group ingress
	scripts/verify-security.sh

verify-app: ## Check readiness and notes API through Nginx
	scripts/verify-app.sh

verify-idempotency: ## Check Terraform plan and optionally run Ansible idempotency verification
	scripts/verify-idempotency.sh

verify: verify-security verify-app verify-idempotency ## Run all verification checks
