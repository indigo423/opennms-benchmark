variable "ip_database" { type = string }
variable "ip_core" { type = string }
variable "ip_kafka" { type = string }
variable "ip_minion" { type = string }
variable "ip_netsim" { type = string }
variable "ip_monitoring" { type = string }
variable "admin_user" { type = string }
variable "ssh_key_path" {
  type        = string
  description = "Path to private SSH key for Ansible"
}
variable "ip_elasticsearch" { type = string }
variable "jump_host" {
  type        = string
  default     = ""
  description = "Optional jump host IP. When set, all VMs except monitoring route through it via ProxyJump. monitoring's ansible_host is set to this IP directly."
}

variable "netsim_sim_interface" {
  type        = string
  description = "Name of the network interface on the netsim VM that carries simulator traffic (10.42.0.0/16). Varies by provider: eth1 (Azure), enp2s0 (KVM), ens19 (Proxmox)."
}
