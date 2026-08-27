# Shared, from lab.tfvars. The per-host address variables that used to live here
# are gone: addresses derive from the deployment spec via ../modules/topology, so
# this root no longer reads lab-addresses.tfvars at all -- the same position aws
# is in. Declaring them "for tfvars compatibility" only made 17 dead variables
# required and forced the caller to keep passing a file nothing consumed.
# Declared but unused: it is in the shared lab.tfvars, which this root does
# consume, and Terraform warns on any value in a var-file the root does not
# declare. kvm and aws are in the same position.
variable "lab_cidr" { type = string }

variable "subnet_db" { type = string }
variable "subnet_kafka" { type = string }
variable "subnet_sim" { type = string }
variable "subnet_mgmt" { type = string }
variable "net_sim_cidr" { type = string }
variable "admin_user" { type = string }

# Proxmox-specific (from proxmox.tfvars)
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox VE API endpoint, e.g. https://192.168.1.10:8006/"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  default     = null
  description = <<-EOT
    Proxmox API token as user@realm!token-name=UUID.

    Optional on purpose, matching the preflight root. Left null, the provider
    falls back to its own PROXMOX_VE_API_TOKEN environment variable, which
    keeps the secret out of proxmox.tfvars and off disk. Prefer that:

      export PROXMOX_VE_API_TOKEN="$PROXMOX_TOKEN_ID=$PROXMOX_API_TOKEN"

    Without a default this variable is required, and deploy.sh applies with
    -input=false -- so following the README's environment-variable recipe gave
    "No value for required variable" rather than a working deploy.
  EOT
}

variable "proxmox_insecure" {
  type        = bool
  default     = false
  description = "Skip TLS certificate verification (set true for self-signed certs)"
}

variable "proxmox_ssh_username" {
  type        = string
  default     = "root"
  description = "SSH username for snippet file uploads — must be a PAM account"
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name where VMs will be created"
}

variable "template_vm_id" {
  type        = number
  description = "VM ID of the Ubuntu 24.04 cloud-init template to clone from"
}

variable "storage_pool" {
  type        = string
  description = "Proxmox datastore for VM disks (e.g. local-lvm)"
}

variable "snippets_datastore" {
  type        = string
  default     = "local"
  description = "File-based datastore for cloud-init snippets — must not be LVM-thin"
}

variable "ssh_key_path" {
  type        = string
  description = "Path to SSH private key (without .pub extension)"
}

variable "bridge_mgmt" {
  type        = string
  default     = "vmbr0"
  description = "Proxmox bridge for management network (192.0.2.192/26)"
}

variable "bridge_db" {
  type        = string
  default     = "vmbr1"
  description = "Proxmox bridge for database subnet (192.0.2.0/26)"
}

variable "bridge_kafka" {
  type        = string
  default     = "vmbr2"
  description = "Proxmox bridge for Kafka subnet (192.0.2.64/26)"
}

variable "bridge_sim" {
  type        = string
  default     = "vmbr3"
  description = "Proxmox bridge for SNMP simulation subnet (192.0.2.128/26)"
}

variable "bridge_ext" {
  type        = string
  default     = "vmbr4"
  description = "Proxmox bridge with external DHCP access — monitoring VM only; its DHCP address serves as the lab jump host"
}

variable "proxmox_machine" {
  type        = string
  default     = "q35"
  description = <<-EOT
    QEMU machine type for the lab VMs. q35 is a modern PCIe chipset; `pc` is
    QEMU's older i440fx.

    Set on the VM rather than inherited from the template, deliberately. The
    guest's NIC names depend on it, so leaving it implicit made the whole lab's
    network configuration depend on a hand-built hypervisor object that this
    repository cannot see or check. Pinning it here means the interface names
    below are derived from a value in version control.
  EOT

  validation {
    condition     = contains(["q35", "pc"], var.proxmox_machine)
    error_message = "proxmox_machine must be \"q35\" or \"pc\"."
  }
}

variable "deployment" {
  type        = string
  description = "Deployment topology slug under deployments/<slug>/, whose topology.yml drives provisioning."
}

variable "vm_id_base" {
  type        = number
  default     = 100
  description = <<-EOT
    First Proxmox VM id. Each node gets vm_id_base plus its role's address-block
    offset plus its index, so ids and addresses come from one scheme and cannot
    disagree as a role's count grows.

    Must leave room below template_vm_id: with 12 roles at role_block_base 4 and
    role_block_size 4 the largest offset is 4 + 11*4 = 48, so a full block puts
    the highest id at base + 51.
  EOT
}

variable "disk_sizes_gb" {
  type        = map(number)
  description = "Disk size in GB per VM"
  default = {
    database      = 50
    core          = 100
    kafka         = 50
    minion        = 20
    netsim        = 20
    monitoring    = 30
    elasticsearch = 50
  }
}

variable "jump_host" {
  type        = string
  default     = ""
  description = "External IP of the monitoring VM for SSH jump host. Set after first apply."
}
