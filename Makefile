# Makefile — lifecycle front-door for the OpenNMS benchmark lab.
#
# Wraps deploy.sh (Terraform provisioning + Ansible configuration) and mirrors
# the CI lint checks, so local and CI commands stay identical. This is the
# single entrypoint: CI invokes these targets rather than the tooling directly.
#
# Common usage:
#   make deploy  PROVIDER=azure
#   make destroy PROVIDER=proxmox           # prompts; CONFIRM=yes to skip
#   make deploy  PROVIDER=kvm V=-vvv TF_ARGS="-var proxmox_insecure=true"
#   make lint                               # fmt + validate + tflint + ansible-lint
#   make help

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Providers with a Terraform root under terraform/<provider>/.
PROVIDERS := azure kvm proxmox vmware

# Deployment library — provider-agnostic topology specs under deployments/<slug>/.
DEPLOYMENTS_DIR := deployments
DESCRIPTOR := python3 $(DEPLOYMENTS_DIR)/bin/topology-descriptor.py

# Ansible verbosity passthrough (e.g. V=-vvv).
V ?=
# Extra args forwarded verbatim to terraform via deploy.sh (e.g. TF_ARGS="-var foo=bar").
TF_ARGS ?=
# Deployment slug from the library (deployments/<slug>/). Consumed by kvm today.
DEPLOYMENT ?= baseline

# The deployment is passed to deploy.sh only for spec-driven providers (kvm),
# which selects both the Terraform topology and the Ansible config overlay.
_dep_flag  = $(if $(filter kvm,$(PROVIDER)),--deployment $(DEPLOYMENT))
# `make plan` still passes the Terraform var directly (it bypasses deploy.sh).
_dep_tfarg = $(if $(filter kvm,$(PROVIDER)),-var deployment=$(DEPLOYMENT))

# ── guards ────────────────────────────────────────────────────────────────────

# guard-FOO fails unless variable FOO is set.  Usage: `target: guard-FOO`.
guard-%:
	@if [ -z "$($*)" ]; then \
	  echo "Error: $* is not set (e.g. make $(firstword $(MAKECMDGOALS)) $*=<value>)" >&2; \
	  exit 1; \
	fi

# check-provider ensures PROVIDER is set and names a known Terraform root.
.PHONY: check-provider
check-provider: guard-PROVIDER
	@case " $(PROVIDERS) " in \
	  *" $(PROVIDER) "*) ;; \
	  *) echo "Error: unknown PROVIDER '$(PROVIDER)' (valid: $(PROVIDERS))" >&2; exit 1 ;; \
	esac

# confirm is an interactive y/N gate for destructive targets; CONFIRM=yes skips it.
.PHONY: confirm
confirm:
ifndef CONFIRM
	@read -r -p "This will DESTROY the '$(PROVIDER)' lab. Continue? [y/N] " ans; \
	  [ "$$ans" = "y" ] || [ "$$ans" = "Y" ] || { echo "Aborted."; exit 1; }
endif

# ── lifecycle (delegates to deploy.sh) ──────────────────────────────────────────

.PHONY: deploy
deploy: check-provider ## Provision + configure the lab (PROVIDER=…, kvm: DEPLOYMENT=<slug>)
	./deploy.sh --provider $(PROVIDER) $(_dep_flag) $(if $(TF_ARGS),--tf-args "$(TF_ARGS)") $(V)

.PHONY: destroy
destroy: check-provider confirm ## Tear down all lab resources for PROVIDER
	./deploy.sh --provider $(PROVIDER) $(_dep_flag) --destroy $(if $(TF_ARGS),--tf-args "$(TF_ARGS)") $(V)

.PHONY: plan
plan: check-provider ## terraform plan for PROVIDER (kvm: DEPLOYMENT=<slug>)
	terraform -chdir=terraform/$(PROVIDER) init -input=false $(if $(filter kvm,$(PROVIDER)),-upgrade) >/dev/null
	terraform -chdir=terraform/$(PROVIDER) plan -input=false \
	  -var-file=../lab.tfvars \
	  $(if $(filter kvm proxmox vmware,$(PROVIDER)),-var-file=../disk-sizes.tfvars) \
	  -var-file=$(PROVIDER).tfvars \
	  $(_dep_tfarg)

# ── lint (mirrors .github/workflows) ────────────────────────────────────────────

.PHONY: fmt
fmt: ## Check Terraform formatting
	terraform fmt -check -recursive terraform/

.PHONY: fmt-fix
fmt-fix: ## Apply Terraform formatting
	terraform fmt -recursive terraform/

# Per-provider targets (validate-azure, tflint-kvm, …) come from pattern rules,
# so they must NOT be listed in .PHONY — that would shadow the pattern rule.
# They never create a file, so make re-runs them every invocation regardless.
.PHONY: validate
validate: $(addprefix validate-,$(PROVIDERS)) ## Validate every provider Terraform root

# -upgrade forces the community libvirt provider to download during kvm init.
validate-%:
	terraform -chdir=terraform/$* init -backend=false $(if $(filter kvm,$*),-upgrade)
	terraform -chdir=terraform/$* validate

.PHONY: tflint
tflint: $(addprefix tflint-,$(PROVIDERS)) ## Run TFLint on every provider Terraform root

tflint-%:
	cd terraform/$* && tflint --init && tflint --recursive --minimum-failure-severity=error

.PHONY: lint-ansible
lint-ansible: ## Run ansible-lint (config in .ansible-lint)
	ansible-lint

# The file lists come from `git ls-files`, so the linters see exactly what is
# tracked: no provider caches under .terraform/, no untracked scratch files, and
# a new script is picked up the moment it is added rather than when someone
# remembers to extend a glob here.
.PHONY: lint-shell
lint-shell: ## Run shellcheck on every tracked shell script
	shellcheck $$(git ls-files '*.sh')

.PHONY: lint-python
lint-python: ## Run ruff on every tracked Python script (config in ruff.toml)
	ruff check $$(git ls-files '*.py')

.PHONY: lint-yaml
lint-yaml: ## Run yamllint on every tracked YAML file (config in .yamllint)
	yamllint $$(git ls-files '*.yml' '*.yaml')

.PHONY: lint
lint: fmt validate tflint lint-ansible lint-shell lint-python lint-yaml validate-deployments ## Run all lint checks

# ── utility ─────────────────────────────────────────────────────────────────────

.PHONY: providers
providers: ## List available providers
	@echo "$(PROVIDERS)"

# ── deployment library ──────────────────────────────────────────────────────────

.PHONY: deployments
deployments: ## List deployments and their canonical descriptors
	@for f in $(DEPLOYMENTS_DIR)/*/topology.yml; do \
	  slug=$$(basename $$(dirname $$f)); \
	  printf "  \033[36m%-22s\033[0m %s\n" "$$slug" "$$($(DESCRIPTOR) $$f 2>/dev/null)"; \
	done

.PHONY: deployment
deployment: guard-DEPLOYMENT ## Show + validate one deployment spec (DEPLOYMENT=<slug>)
	@f="$(DEPLOYMENTS_DIR)/$(DEPLOYMENT)/topology.yml"; \
	[ -f "$$f" ] || { echo "Error: no such deployment '$(DEPLOYMENT)' ($$f not found)" >&2; exit 1; }; \
	$(DESCRIPTOR) --validate "$$f" && echo && cat "$$f"

.PHONY: validate-deployments
validate-deployments: ## Validate every deployment spec against the schema
	@rc=0; for f in $(DEPLOYMENTS_DIR)/*/topology.yml; do \
	  $(DESCRIPTOR) --validate "$$f" >/dev/null || { $(DESCRIPTOR) --validate "$$f"; rc=1; }; \
	done; [ $$rc -eq 0 ] && echo "all deployment specs valid" || exit $$rc

.PHONY: help
help: ## Show this help
	@echo "OpenNMS benchmark lab — make targets:"
	@grep -hE '^[a-zA-Z][a-zA-Z_-]*:.*## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables: PROVIDER=<$(shell echo $(PROVIDERS) | tr ' ' '|')>  V=-vvv  TF_ARGS=\"...\"  CONFIRM=yes"
