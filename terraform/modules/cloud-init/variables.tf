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
    address = string
    prefix  = number
    gateway = optional(string)
  }))
  description = "Network interfaces to configure via cloud-init network-config v2"
}

variable "extra_routes" {
  type = list(object({
    to  = string
    via = string
  }))
  default     = []
  description = "Additional static routes (used for Minion SNMP simulation routing)"
}

variable "hosts" {
  type        = map(string)
  description = "Hostname to IP map for /etc/hosts injection"
}
