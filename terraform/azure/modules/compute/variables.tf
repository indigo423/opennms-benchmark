variable "resource_group" { type = string }
variable "location" { type = string }
variable "ppg_id" { type = string }
variable "vm_size_small" { type = string }
variable "vm_size_medium" { type = string }
variable "priority" { type = string }
variable "admin_user" { type = string }
variable "ssh_public_key" {
  type      = string
  sensitive = true
}

# /etc/hosts map injected into every node's cloud-init.
variable "hosts" { type = map(string) }

# NIC IDs keyed "<role>-<subnet>", from the network module.
variable "nic_ids" { type = map(string) }

# Topology spec (keyed by role); see terraform/azure/main.tf for the schema.
variable "topology" {
  type = map(object({
    vm_name   = string
    nic_label = string
    size      = string
    public_ip = bool
    interfaces = list(object({
      subnet  = string
      address = string
      routes  = list(object({ to = string, via = string }))
    }))
  }))
}
