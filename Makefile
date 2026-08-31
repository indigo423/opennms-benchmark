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
PROVIDERS := aws azure kvm proxmox vmware

# Terraform roots that are not providers, relative to terraform/. Only `validate`
# needs to know about them: `fmt` is recursive over terraform/, and `tflint-%`
# runs `tflint --recursive` from the provider root, so both already reach a
# nested root. These are never deployed — they carry no `make deploy` path and
# stay out of PROVIDERS on purpose.
EXTRA_TF_ROOTS := proxmox/preflight

# Deployment library — provider-agnostic topology specs under deployments/<slug>/.
DEPLOYMENTS_DIR := deployments
DESCRIPTOR := python3 $(DEPLOYMENTS_DIR)/bin/topology-descriptor.py

# Ansible verbosity passthrough (e.g. V=-vvv).
V ?=
# Extra args forwarded verbatim to terraform via deploy.sh (e.g. TF_ARGS="-var foo=bar").
TF_ARGS ?=
# Deployment slug from the library (deployments/<slug>/). Consumed by kvm, aws
# and proxmox; azure and vmware still deploy the fixed baseline.
DEPLOYMENT ?= baseline

# The deployment is passed to deploy.sh only for spec-driven providers,
# which selects both the Terraform topology and the Ansible config overlay.
_dep_flag  = $(if $(filter kvm aws proxmox,$(PROVIDER)),--deployment $(DEPLOYMENT))
# `make plan` still passes the Terraform var directly (it bypasses deploy.sh).
_dep_tfarg = $(if $(filter kvm aws proxmox,$(PROVIDER)),-var deployment=$(DEPLOYMENT))
# Generated Ansible inputs are provider-scoped (#277): one inventory and one
# endpoints manifest per PROVIDER, so two labs can be operated from one checkout.
INVENTORY  = ansible-inventory.$(PROVIDER).yml

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

.PHONY: show
show: check-provider ## Show deployed resources for PROVIDER, and any leftovers
	./show.sh --provider $(PROVIDER) $(_dep_flag)

# Hypervisor preparation is separate from `make deploy` on purpose: it configures
# the hypervisor rather than the lab, needs privileges the lab stack's API token
# does not, and is a prerequisite rather than a step. It also edits network
# configuration on the host it connects over, so have out-of-band access.
.PHONY: prepare-hypervisor
prepare-hypervisor: guard-HYPERVISOR ## Prepare a Proxmox hypervisor for the lab (HYPERVISOR=<host>)
	ansible-playbook -i '$(HYPERVISOR),' bootstrap/proxmox-hypervisor-playbook.yml $(V)

.PHONY: plan
# aws only: terraform cannot read the token cache `aws login` writes, so without
# this the target fails on credentials even when the CLI works. deploy.sh does
# the same thing; `make plan` bypasses deploy.sh and so needs its own.
_aws_creds = $(if $(filter aws,$(PROVIDER)),eval "$$(aws configure export-credentials --format env 2>/dev/null)"; unset AWS_PROFILE;,)

plan: check-provider ## terraform plan for PROVIDER (kvm: DEPLOYMENT=<slug>)
	terraform -chdir=terraform/$(PROVIDER) init -input=false $(if $(filter kvm,$(PROVIDER)),-upgrade) >/dev/null
	$(_aws_creds) \
	terraform -chdir=terraform/$(PROVIDER) plan -input=false \
	  -var-file=../lab.tfvars \
	  $(if $(filter-out aws proxmox,$(PROVIDER)),-var-file=../lab-addresses.tfvars) \
	  $(if $(filter aws kvm proxmox vmware,$(PROVIDER)),-var-file=../disk-sizes.tfvars) \
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
validate: $(addprefix validate-,$(PROVIDERS)) validate-extra-roots ## Validate every Terraform root

# -upgrade forces the community libvirt provider to download during kvm init.
validate-%:
	terraform -chdir=terraform/$* init -backend=false $(if $(filter kvm,$*),-upgrade)
	terraform -chdir=terraform/$* validate

# A loop rather than validate-$(EXTRA_TF_ROOTS) through the pattern rule above:
# make strips the directory part of a target name before matching an implicit
# rule, so `validate-proxmox/preflight` would try to match `preflight` against
# `validate-%` and find no rule.
.PHONY: validate-extra-roots
validate-extra-roots: ## Validate the non-provider Terraform roots
	@rc=0; for r in $(EXTRA_TF_ROOTS); do \
	  terraform -chdir=terraform/$$r init -backend=false >/dev/null || { rc=1; continue; }; \
	  terraform -chdir=terraform/$$r validate || rc=1; \
	done; exit $$rc

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

# actionlint covers workflow schema, expression typing and the shell inside
# `run:`; zizmor covers the Actions-specific security surface (template
# injection, credential persistence, over-broad permissions). Together they
# enforce the hardening rules — SHA pins, least privilege, timeouts — that were
# applied by hand and would otherwise decay to whoever remembers them.
# Install the same versions CI pins, or `make lint-actions` means one thing on
# your machine and another in CI — the drift ruff.toml exists to prevent:
#   go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
#   pipx install zizmor==1.28.0
#
# --no-online-audits keeps the run deterministic and token-free, at a cost worth
# stating: it disables impostor-commit (is this SHA a real commit of that repo?)
# and ref-version-mismatch (does the `# vX.Y.Z` comment match the pinned SHA?).
# Both are exactly the conventions this repo pins by hand, so offline mode will
# not catch a forged or mislabelled pin. Enabling them needs a GH token on a
# required check — tracked separately.
.PHONY: lint-actions
lint-actions: ## Lint GitHub Actions workflows (actionlint + zizmor)
	actionlint
	zizmor --no-online-audits .github/workflows/

# Ansible ships no lockfile, so requirements.yml is the manifest and nothing
# else verifies it. This asserts the installed set matches the declared closure
# exactly, that every collection's dependencies are declared and satisfied, and
# that the pinned ansible-core sits inside every requires_ansible range — those
# are two-sided, and a floor-only check misses a ceiling breach.
#
# COLLECTIONS_PATH mirrors what the install target and CI use.
COLLECTIONS_PATH ?= ~/.ansible/collections

# --no-deps is the point, not an optimisation: it turns off the resolver so
# requirements.yml is authoritative rather than a starting point. With the
# resolver on, a complete manifest and an incomplete one behave identically
# until a rebuild months later silently resolves a transitive dependency
# differently. --force makes the install idempotent, so a control node holding
# a different version converges instead of being skipped.
#
# The version-mismatch override is deliberate and scoped to this command.
# ansible.cfg sets collections_on_ansible_version_mismatch=error, which applies
# to ansible-galaxy too: it loads the *currently installed* collections while
# running, so a control node holding a collection outside its requires_ansible
# range cannot install the manifest that fixes it. An installer that refuses to
# run from the broken state it exists to repair is useless. Plays and
# validate-collections keep the strict setting; converging state does not.
.PHONY: install-collections
install-collections: ## Install the pinned collection closure (resolver off)
	ANSIBLE_COLLECTIONS_ON_ANSIBLE_VERSION_MISMATCH=ignore \
	  ansible-galaxy collection install -r requirements.yml -p $(COLLECTIONS_PATH) --no-deps --force

.PHONY: validate-collections
validate-collections: ## Assert installed collections match the declared closure
	python3 validate-collections.py --path $(COLLECTIONS_PATH)

# --no-deps --force never removes anything, so dropping a collection from
# requirements.yml leaves it installed on every existing control node forever
# and validate-collections reports it as "installed but not declared". This is
# the remedy, and it is destructive by design: wipe the tree and reinstall from
# the manifest, which is the only way to be sure the two agree.
.PHONY: clean-collections
clean-collections: ## Remove the installed collection tree, then reinstall the manifest
	rm -rf $(COLLECTIONS_PATH)/ansible_collections
	$(MAKE) install-collections

.PHONY: lint
lint: fmt validate tflint lint-ansible lint-shell lint-python lint-yaml lint-actions validate-deployments validate-library validate-topology validate-collections ## Run all lint checks

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

.PHONY: experiment
experiment: check-provider guard-EXPERIMENT ## Run an experiment (PROVIDER=<p>, EXPERIMENT=<name>, DEPLOYMENT=<slug> to layer its vars)
	@d="experiments/$(EXPERIMENT)"; \
	[ -f "$$d/experiment.yml" ] || { echo "Error: no such experiment '$(EXPERIMENT)' ($$d/experiment.yml not found)" >&2; exit 1; }; \
	[ -f $(INVENTORY) ] || { echo "Error: $(INVENTORY) not found; deploy first" >&2; exit 1; }; \
	[ -f lab-endpoints.$(PROVIDER).json ] || { echo "Error: lab-endpoints.$(PROVIDER).json not found; run 'make endpoints PROVIDER=$(PROVIDER) DEPLOYMENT=...'" >&2; exit 1; }
	ansible-playbook --become -i $(INVENTORY) \
	  experiments/$(EXPERIMENT)/experiment.yml \
	  --extra-vars="lab_provider=$(PROVIDER)" \
	  --extra-vars="@opennms-lab-vars.yml" \
	  $(if $(wildcard $(DEPLOYMENTS_DIR)/$(DEPLOYMENT)/opennms-lab-vars.yml),--extra-vars="@$(DEPLOYMENTS_DIR)/$(DEPLOYMENT)/opennms-lab-vars.yml") \
	  $(if $(wildcard experiments/$(EXPERIMENT)/opennms-lab-vars.yml),--extra-vars="@experiments/$(EXPERIMENT)/opennms-lab-vars.yml")

.PHONY: experiments
experiments: ## List runnable experiments
	@for f in experiments/*/experiment.yml; do \
	  [ -f "$$f" ] || continue; \
	  printf "  \033[36m%s\033[0m\n" "$$(basename $$(dirname $$f))"; \
	done; \
	echo "  (playbook-driven only; experiments/legacy/ is reference, and"; \
	echo "   nms-20027-painless-flows is a standalone harness with its own"; \
	echo "   runner — see experiments/README.md)"

.PHONY: endpoints
endpoints: check-provider ## Publish lab-endpoints.<provider>.yml for a running lab (PROVIDER=…, DEPLOYMENT=<slug>)
	@[ -f $(INVENTORY) ] || { echo "Error: $(INVENTORY) not found; deploy first" >&2; exit 1; }
	@[ -n "$(PROVIDER)" ] && [ -n "$(DEPLOYMENT)" ] || { echo "Error: set PROVIDER and DEPLOYMENT, or the manifest records neither" >&2; exit 1; }
	ansible-playbook -i $(INVENTORY) endpoints-playbook.yml \
	  --extra-vars="@opennms-lab-vars.yml" \
	  $(if $(DEPLOYMENT),--extra-vars="lab_deployment=$(DEPLOYMENT)") \
	  $(if $(PROVIDER),--extra-vars="lab_provider=$(PROVIDER)") \
	  $(if $(wildcard $(DEPLOYMENTS_DIR)/$(DEPLOYMENT)/opennms-lab-vars.yml),--extra-vars="@$(DEPLOYMENTS_DIR)/$(DEPLOYMENT)/opennms-lab-vars.yml")

.PHONY: validate-topology
validate-topology: ## Assert every deployment spec renders a provisionable topology
	./validate-topology.sh

.PHONY: validate-deployments
validate-deployments: ## Validate every deployment spec against the schema
	@rc=0; for f in $(DEPLOYMENTS_DIR)/*/topology.yml; do \
	  $(DESCRIPTOR) --validate "$$f" >/dev/null || { $(DESCRIPTOR) --validate "$$f"; rc=1; }; \
	done; [ $$rc -eq 0 ] && echo "all deployment specs valid" || exit $$rc

# Separate from validate-deployments because the unit differs: that target
# judges each spec on its own, this one judges the library and the provider
# roots together. Neither can see what the other checks.
.PHONY: validate-library
validate-library: ## Assert the invariants that span the whole deployment library
	@python3 $(DEPLOYMENTS_DIR)/bin/validate-library.py

.PHONY: help
help: ## Show this help
	@echo "OpenNMS benchmark lab — make targets:"
	@grep -hE '^[a-zA-Z][a-zA-Z_-]*:.*## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables: PROVIDER=<$(shell echo $(PROVIDERS) | tr ' ' '|')>  V=-vvv  TF_ARGS=\"...\"  CONFIRM=yes"
