terraform {
  # 1.5 is the repo-wide floor and is also what `check` blocks require; the
  # rung reports below are checks rather than validations so a preflight run
  # reports every problem it finds instead of stopping at the first.
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.99"
    }
  }
}

# Deliberately identical to the lab stack's provider block. The point of the
# preflight is to exercise the same authentication and transport the lab stack
# uses, so any divergence here would make a passing preflight meaningless.
#
# The ssh block is not optional for this stack. The Proxmox API refuses
# `snippets` uploads, so the provider opens an SSH session and writes the file
# over SFTP. An API token carries no password for that session to inherit, so
# the credential must come from an agent, and the account must be a PAM account
# because non-PAM accounts cannot upload snippets at all.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
