variable "proxmox_node" { type = string }
variable "template_vm_id" { type = number }
variable "storage_pool" { type = string }
variable "snippets_datastore" { type = string }
variable "admin_user" { type = string }
variable "ssh_public_key" {
  type      = string
  sensitive = true
}
variable "net_sim_cidr" { type = string }
variable "net_sim_gateway" { type = string }
variable "hosts" { type = map(string) }
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
variable "bridge_mgmt" { type = string }
variable "gateway_mgmt" { type = string }
variable "bridge_db" { type = string }
variable "bridge_kafka" { type = string }
variable "bridge_sim" { type = string }
variable "bridge_ext" { type = string }
variable "vm_ids" { type = map(number) }
variable "ip_elasticsearch" { type = string }
variable "ip_es_core" { type = string }

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
