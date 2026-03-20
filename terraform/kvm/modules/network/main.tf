terraform {
  required_version = ">= 1.5"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7"
    }
  }
}

# KVM uses 4 isolated bridge networks — one per subnet segment.
# This is equivalent to Azure's single VNet with 4 subnets.

resource "libvirt_network" "db" {
  name      = "lab-db"
  mode      = "none" # isolated — no NAT, no DHCP
  addresses = [var.subnet_db]
  autostart = true
}

resource "libvirt_network" "kafka" {
  name      = "lab-kafka"
  mode      = "none"
  addresses = [var.subnet_kafka]
  autostart = true
}

resource "libvirt_network" "sim" {
  name      = "lab-sim"
  mode      = "none"
  addresses = [var.subnet_sim]
  autostart = true
}

resource "libvirt_network" "mgmt" {
  name      = "lab-mgmt"
  mode      = "nat" # NAT on mgmt — operator SSH access from host
  addresses = [var.subnet_mgmt]
  autostart = true
}
