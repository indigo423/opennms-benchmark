variable "storage_pool" { type = string }
variable "ubuntu_cloud_image" { type = string }
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
variable "network_db_id" { type = string }
variable "network_kafka_id" { type = string }
variable "network_sim_id" { type = string }
variable "extra_packages" {
  type    = list(string)
  default = ["qemu-guest-agent"]
}
variable "network_mgmt_id" { type = string }
variable "gateway_mgmt" { type = string }
variable "network_external_id" { type = string }
variable "disk_sizes_gb" {
  type        = map(number)
  description = "Disk size in GB per VM"
  default = {
    database   = 20
    core       = 30
    kafka      = 20
    minion     = 20
    netsim     = 20
    monitoring = 30
  }
}
