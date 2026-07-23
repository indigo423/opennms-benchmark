variable "resource_group" { type = string }
variable "location" { type = string }
variable "environment" { type = string }
variable "vnet_name" { type = string }
variable "lab_cidr" { type = string }
variable "subnet_db" { type = string }
variable "subnet_kafka" { type = string }
variable "subnet_sim" { type = string }
variable "subnet_mgmt" { type = string }
variable "operator_cidr" { type = string }

# Topology spec (keyed by role). NICs are derived from each role's interfaces;
# see terraform/azure/main.tf for the schema and the current layout.
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
