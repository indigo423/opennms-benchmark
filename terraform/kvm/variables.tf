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
variable "net_sim_gateway" { type = string }
variable "admin_user" { type = string }
variable "vm_names" {
  type = map(string)
}
variable "ip_elasticsearch" { type = string }
variable "ip_es_core" { type = string }

# KVM-specific (from kvm.tfvars)
variable "libvirt_uri" { type = string }
variable "storage_pool" { type = string }
variable "ubuntu_cloud_image" { type = string }
variable "ssh_key_path" { type = string }
variable "bridge_name" { type = string }
variable "jump_host" {
  type    = string
  default = ""
}
