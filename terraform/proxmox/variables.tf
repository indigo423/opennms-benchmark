# Shared (from lab.tfvars) — declared for cross-provider tfvars compatibility; not used by this module
variable "lab_cidr" { type = string }
variable "subnet_db" { type = string }
variable "subnet_kafka" { type = string }
variable "subnet_sim" { type = string }
variable "subnet_mgmt" { type = string }
variable "ip_database" { type = string }
variable "ip_core" { type = string }
variable "ip_kafka" { type = string }
variable "ip_minion" { type = string }
variable "ip_netsim" { type = string }
variable "ip_monitoring" { type = string }
variable "ip_database_db" { type = string }
variable "ip_core_db" { type = string }
variable "ip_core_kafka" { type = string }
variable "ip_kafka_kafka" { type = string }
variable "ip_minion_kafka" { type = string }
variable "ip_minion_sim" { type = string }
variable "ip_netsim_sim" { type = string }
variable "net_sim_cidr" { type = string }
variable "net_sim_gateway" { type = string }
variable "admin_user" { type = string }
variable "vm_names" {
  type    = map(string)
  default = null # accepted from lab.tfvars; not used by this module
}
variable "ip_elasticsearch" { type = string }
variable "ip_es_core" { type = string }

# Proxmox-specific (from proxmox.tfvars)
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox VE API endpoint, e.g. https://192.168.1.10:8006/"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token in the format user@realm!token-name=UUID"
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

variable "vm_ids" {
  type        = map(number)
  description = "Proxmox VM ID per VM name — must be unique across the cluster"
  default = {
    database      = 196
    core          = 197
    kafka         = 198
    minion        = 199
    monitoring    = 200
    netsim        = 201
    elasticsearch = 202
  }
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
