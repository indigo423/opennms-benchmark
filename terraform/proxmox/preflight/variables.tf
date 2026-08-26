# The rung selector is the whole interface of this stack. One mechanism per
# apply, in dependency order, so a failure names its own cause.
variable "rung" {
  type        = number
  default     = 0
  description = <<-EOT
    Which preflight rung to run. Each rung isolates one mechanism:
      0  API token authentication, endpoint URL scheme, TLS trust  (creates nothing)
      1  node names, datastore names and content types             (creates nothing)
      2  SSH agent -> PAM account -> SFTP -> snippets datastore    (creates one file)
      3  template clone, cloud-init delivery, guest agent          (creates one VM)
    Reads are cumulative, creates are exclusive: rung 3 does not create rung 2's
    probe file, and no rung creates the resources of a later one.
  EOT

  validation {
    condition     = var.rung >= 0 && var.rung <= 3 && floor(var.rung) == var.rung
    error_message = "rung must be one of 0, 1, 2, 3."
  }
}

# ── Proxmox connection (from proxmox.tfvars) ──────────────────────────────────

variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox VE API endpoint. Must be https: port 8006 redirects http with a 301, which the provider does not follow."
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  default     = null
  description = <<-EOT
    Proxmox API token as user@realm!token-name=UUID.

    Optional on purpose. Left null, the provider falls back to its own
    PROXMOX_VE_API_TOKEN environment variable, which keeps the secret out of
    proxmox.tfvars and off disk entirely. Prefer that:

      export PROXMOX_VE_API_TOKEN="$PROXMOX_TOKEN_ID=$PROXMOX_API_TOKEN"
  EOT
}

variable "proxmox_insecure" {
  type        = bool
  default     = false
  description = "Skip TLS verification. Required unless the node's PVE Cluster Manager CA is in the local trust store."
}

variable "proxmox_ssh_username" {
  type        = string
  default     = "root"
  description = "SSH username for snippet uploads. Must be a PAM account, and a key for it must be loaded in the operator's SSH agent."
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name. This is the node's own name, not necessarily the API hostname."
}

# ── rung 2 ───────────────────────────────────────────────────────────────────

variable "snippets_datastore" {
  type        = string
  default     = "local"
  description = "File-based datastore for cloud-init snippets. Must permit the 'snippets' content type, which a default PVE installation does not enable. LVM-thin datastores cannot hold snippets at all."
}

# ── rung 3 ───────────────────────────────────────────────────────────────────

variable "template_vm_id" {
  type        = number
  default     = 9000
  description = "VM ID of the Ubuntu 24.04 cloud-init template to clone from"
}

variable "storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Datastore for the preflight VM's disk"
}

variable "ssh_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa"
  description = "Path to the SSH private key for the VM admin user, without the .pub extension"
}

variable "admin_user" {
  type        = string
  default     = "labuser"
  description = "Admin user created on the preflight VM. Defaults so this stack runs from proxmox.tfvars alone, without the shared lab.tfvars."
}

variable "preflight_vm_id" {
  type        = number
  default     = 9999
  description = "VM ID for the preflight VM. Must not collide with the lab stack's vm_ids (196-202) or the template (9000)."

  # The template collision the description also promises is asserted as a
  # lifecycle precondition on the VM in main.tf, not here: cross-variable
  # validation needs Terraform 1.9 and this root declares >= 1.5.
  validation {
    condition     = var.preflight_vm_id < 196 || var.preflight_vm_id > 202
    error_message = "preflight_vm_id must sit outside 196-202, which the lab stack's vm_ids claim."
  }
}

variable "preflight_bridge" {
  type        = string
  default     = "vmbr0"
  description = <<-EOT
    Bridge for the preflight VM's single NIC. Deliberately the bridge carrying
    the hypervisor's own uplink, so rung 3 depends on neither the four isolated
    lab bridges nor management-subnet routing. That keeps a rung 3 failure
    attributable to the template, the clone, or cloud-init.
  EOT
}

# The guest's NIC name, which is a function of the VM's machine type and is NOT
# safe to assume. On PVE's default i440fx a virtio NIC appears as ens18; with
# machine=q35 the same NIC appears as enp6s18, because it lands on a PCIe bridge.
# The machine type comes from the hand-built template, so it is not visible
# anywhere in this repository.
#
# Verified empirically by rung 3 rather than assumed: a name that matches no
# device means netplan configures nothing, the guest never sends a frame, apt
# cannot install qemu-guest-agent, and Terraform times out waiting for an agent
# that can never appear.
variable "preflight_interface" {
  type        = string
  default     = "ens18"
  description = "Guest NIC name. ens18 on i440fx, enp6s18 on q35."
}

# Optional static addressing, for re-running rung 3 on the management bridge
# after host preparation to prove the hypervisor actually routes and resolves.
#
# Rung 3's default stays DHCP-on-the-uplink-bridge so its failures stay
# attributable to the template, the clone, or cloud-init. These overrides answer
# a different, later question: does the prepared host route this subnet?
variable "preflight_address" {
  type        = string
  default     = null
  description = "Static IPv4 address for the preflight VM. Null selects DHCP."
}

variable "preflight_prefix" {
  type        = number
  default     = null
  description = "Prefix length for preflight_address"
}

variable "preflight_gateway" {
  type        = string
  default     = null
  description = "Default gateway for preflight_address. cloud-init also uses this as the resolver unless preflight_nameservers is set, which is why the hypervisor must answer DNS on it."
}

variable "preflight_nameservers" {
  type        = list(string)
  default     = null
  description = "Resolvers for the preflight VM. Null defers to modules/cloud-init, which falls back to the gateway address."
}

variable "preflight_disk_gb" {
  type        = number
  default     = 8
  description = "Disk size for the preflight VM. The minimum that comfortably boots Ubuntu 24.04."
}

# ── Declared for tfvars compatibility ────────────────────────────────────────
#
# This stack is invoked with the lab stack's proxmox.tfvars so credentials live
# in one place. Terraform warns on every value in a var-file that the root
# module does not declare, so the lab-only variables are declared here and left
# unused. Same convention as terraform/proxmox/variables.tf, which declares the
# shared lab.tfvars variables it does not consume.

variable "bridge_mgmt" {
  type    = string
  default = null
}

variable "bridge_db" {
  type    = string
  default = null
}

variable "bridge_kafka" {
  type    = string
  default = null
}

variable "bridge_sim" {
  type    = string
  default = null
}

variable "bridge_ext" {
  type    = string
  default = null
}

variable "vm_ids" {
  type    = map(number)
  default = null
}

variable "disk_sizes_gb" {
  type    = map(number)
  default = null
}

variable "jump_host" {
  type    = string
  default = null
}
