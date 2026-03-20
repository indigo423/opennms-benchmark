variable "ip_database" { type = string }
variable "ip_core"     { type = string }
variable "ip_kafka"    { type = string }
variable "ip_minion"   { type = string }
variable "ip_snmpsim"  { type = string }
variable "ip_monitoring" { type = string }
variable "admin_user"  { type = string }
variable "ssh_key_path" {
  type        = string
  description = "Path to private SSH key for Ansible"
}
