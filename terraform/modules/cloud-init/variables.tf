variable "vm_name" {
  type        = string
  description = "VM identifier used in hostname and hosts file"
}

variable "admin_user" {
  type        = string
  description = "Admin username injected into cloud-init user-data"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for admin user"
}

variable "interfaces" {
  type = list(object({
    name    = string
    address = optional(string)
    prefix  = optional(number)
    gateway = optional(string)
    routes  = optional(list(object({ to = string, via = string })), [])
  }))
  description = "Network interfaces to configure via cloud-init network-config v2. Set address=null for DHCP. Use routes for per-interface static routes."

  validation {
    condition = (
      length(flatten([for iface in var.interfaces : [for r in iface.routes : r.to]])) ==
      length(distinct(flatten([for iface in var.interfaces : [for r in iface.routes : r.to]])))
    )
    error_message = "Duplicate route destination detected across interfaces. Each 'to' CIDR must appear at most once. Check interfaces[*].routes for repeated destinations."
  }
}

variable "hosts" {
  type        = map(string)
  description = "Hostname to IP map for /etc/hosts injection"
}

variable "extra_packages" {
  type        = list(string)
  default     = []
  description = "Additional packages to install via cloud-init. Use for provider-specific agents (e.g. qemu-guest-agent for KVM)."
}

variable "local_routes" {
  type        = list(string)
  default     = []
  description = "CIDRs to add as local routes on the loopback interface (ip route add local <cidr> dev lo). Installed as a persistent systemd service so routes survive reboots."
}

variable "network_config_supported" {
  type        = bool
  default     = true
  description = "Set to false on providers that cannot deliver a separate cloud-init network-config document (e.g. Azure). When false, static interface routes are installed via a systemd service in user-data instead of relying on netplan."
}
