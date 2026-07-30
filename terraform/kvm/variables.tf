# Shared (from lab.tfvars)
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
# Declared but deliberately unused: kvm derives the simulated-network next hop
# from the topology (#171), because a hardcoded value drifts as soon as the
# address allocation changes. azure, proxmox and vmware still consume it, so it
# stays in lab.tfvars — and stays declared here so that shared file parses
# without an undeclared-variable warning. Do not wire this back into a route.
# tflint-ignore: terraform_unused_declarations
variable "net_sim_gateway" { type = string }
variable "admin_user" { type = string }
variable "vm_names" {
  type = map(string)
}
variable "ip_elasticsearch" { type = string }
variable "ip_es_core" { type = string }

# Deployment selector — resolves deployments/<deployment>/topology.yml.
variable "deployment" {
  type        = string
  default     = "baseline"
  description = "Deployment slug under deployments/; selects the topology spec to provision."
}

# KVM-specific (from kvm.tfvars)
variable "libvirt_uri" { type = string }
variable "storage_pool" { type = string }
variable "ubuntu_cloud_image" { type = string }
variable "ssh_key_path" { type = string }
variable "bridge_name" { type = string }
# CIDR of the physical LAN behind bridge_name, used by the 'lab' subnet type
# ("" when no selected deployment uses it). Follows the subnet_<type> naming of
# the internal subnets above. NOT the same as lab_cidr, which is the internal
# supernet (192.0.2.0/24) those carve out of.
variable "subnet_lab" {
  type    = string
  default = ""
}
# Resolvers for lab-subnet NICs; empty = fall back to the gateway (which some
# physical LANs, unlike the libvirt NAT networks, do not run a resolver on).
variable "lab_nameservers" {
  type    = list(string)
  default = []
}
variable "jump_host" {
  type    = string
  default = ""
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
