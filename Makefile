.PHONY: help up down ssh-app ssh-db

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
