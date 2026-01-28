.PHONY: init validate fmt lint plan apply destroy

init:
	terraform init

validate: init
	terraform validate

fmt:
	terraform fmt -recursive

lint: fmt validate
	@echo "Lint passed"

plan: init
	terraform plan

apply: init
	terraform apply

destroy: init
	terraform destroy
