# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

# Shared (from lab.tfvars). Only structural values are read here: this provider
# derives every per-host address from the deployment spec, so the ip_* variables
# the legacy providers declare are deliberately absent (#161, #174).
#
# They live in lab-addresses.tfvars, which deploy.sh does not pass to this
# provider. Declaring them here to accept the shared file would reintroduce the
# per-host constants this provider exists to avoid, and tflint would then flag
# every one as unused.
variable "lab_cidr" { type = string }
variable "subnet_db" { type = string }
variable "subnet_kafka" { type = string }
variable "subnet_sim" { type = string }
variable "subnet_mgmt" { type = string }
variable "net_sim_cidr" { type = string }
variable "admin_user" { type = string }

# Disk sizes (from disk-sizes.tfvars)
variable "disk_sizes_gb" {
  type        = map(number)
  description = "Provider role -> root volume size in GiB."
  default     = {}
}

variable "deployment" {
  type        = string
  default     = "baseline"
  description = "Deployment slug under deployments/; selects the topology spec to provision."
}

variable "region" {
  type        = string
  description = "AWS region. All subnets live in one availability zone within it, because an ENI is bound to a single AZ."
}

variable "availability_zone" {
  type        = string
  default     = ""
  description = "AZ for every subnet. Empty selects the region's first available zone. A single AZ is deliberate: ENIs cannot span zones, and a benchmark wants consistent inter-node latency anyway."
}

variable "allowed_account_ids" {
  type        = list(string)
  default     = []
  description = "Account IDs this lab may be provisioned into. Terraform refuses to run anywhere else, which is what stops a stray AWS_PROFILE from building a benchmark bed next to production. Empty disables the check, for anyone without a dedicated account."
}

variable "project_name" { type = string }
variable "environment" { type = string }

variable "ssh_key_path" {
  type        = string
  description = "Path to the private SSH key; the .pub alongside it is uploaded as the EC2 key pair."
}

variable "public_subnet_cidr" {
  type        = string
  default     = "198.51.100.0/28"
  description = "Public subnet, added to the VPC as a secondary CIDR because the lab supernet fills its whole /24. Hosts the NAT gateway that gives private nodes their egress, and the jump host's internet-facing NIC. RFC 5737 TEST-NET-2 by default, matching the lab's use of TEST-NET-3."
}

variable "operator_cidr" {
  type = string
  # Fail closed. deploy.sh detects the caller's address and passes it, and falls
  # back to this same value when detection fails, so a real deploy is unaffected.
  # The default exists so `make plan` works: it bypasses deploy.sh and therefore
  # has nothing to detect with, which made planning the provider impossible.
  #
  # 0.0.0.0/32 is a single unroutable address, so an unset value yields a lab
  # nobody can SSH to rather than one open to the world.
  default     = "0.0.0.0/32"
  description = "CIDR permitted to reach the jump host over SSH and HTTPS. deploy.sh supplies the caller's address; the default is deliberately unreachable."
}

variable "cost_profile" {
  type = string
  # Defaults to the cheap tier on purpose. The expensive mistake is provisioning
  # measurement-grade instances without meaning to; the cheap mistake is a run
  # that has to be repeated. Cost is opted into, not out of.
  #
  # The risk this creates -- a smoke lab mistaken for a benchmark -- is handled
  # by making the profile impossible to miss rather than by defaulting to spend:
  # deploy.sh announces it before provisioning and warns at the end, every
  # instance is tagged, every host carries lab_cost_profile in the inventory,
  # and `terraform output cost_profile` states it.
  default     = "smoke"
  description = "'benchmark' for measurement-grade infrastructure, or 'smoke' for the cheapest shape that still starts the stack. Defaults to 'smoke' so cost is opted into; a smoke lab is for proving wiring, never for producing numbers."

  validation {
    condition     = contains(["benchmark", "smoke"], var.cost_profile)
    error_message = "cost_profile must be 'benchmark' or 'smoke'."
  }
}

variable "spot" {
  type        = bool
  default     = false
  description = "Request spot capacity. Roughly 70% cheaper, at the cost of interruption mid-run. Sensible for a smoke test, not for a measurement, and refused outright when cost_profile is 'benchmark'."
}

variable "smoke_max_disk_gb" {
  type        = number
  default     = 20
  description = "Root volume cap under the smoke profile. Ubuntu needs roughly 10 GiB; the benchmark sizes (up to 100 GiB for core) exist to hold data a smoke test never generates."
}

# ── instance sizing ───────────────────────────────────────────────────────────
# Deliberately NOT burstable. A t-class instance depletes its CPU credits partway
# through a sustained run, so the second half of a measurement is not comparable
# to the first — the lab's whole output is benchmark numbers, and Azure's use of
# Standard_B2ms/B4ms is a latent measurement bug this provider does not inherit.
variable "instance_types" {
  type        = map(string)
  description = "T-shirt size class -> EC2 instance type. All five classes are in use across the deployment library."
  default = {
    tiny   = "m6i.large"
    small  = "m6i.large"
    medium = "m6i.xlarge"
    large  = "m6i.xlarge"
    xlarge = "m6i.2xlarge"
    # 8 vCPU / 32 GiB: the one class whose memory EC2's fixed vCPU:RAM ratio
    # matches exactly. Same type as xlarge, which that ratio oversizes, so the
    # two are indistinguishable here and the class asserts nothing aws honours.
    # The 8 vCPU / 32 GiB contract is real only on kvm and proxmox. Kept so the
    # Deployment Topologies job can render a spec using this class through the
    # aws root.
    xxlarge-mem = "m6i.2xlarge"
  }
}

# Burstable on purpose here, and ONLY here. Credit depletion makes these
# useless for measurement, which is exactly why they are confined to the smoke
# profile: the goal is proving the stack comes up, not timing it. Sizes track
# the memory floor in the size_map rather than its vCPU counts.
variable "instance_types_smoke" {
  type        = map(string)
  description = "T-shirt size class -> EC2 instance type under the smoke profile."
  # Nothing below t3a.medium: t3a.small offers only 2 ENIs, and core and minion
  # both take 3. The saving from a smaller type is not worth a tier that cannot
  # run half the deployment library.
  default = {
    tiny   = "t3a.medium"
    small  = "t3a.medium"
    medium = "t3a.medium"
    large  = "t3a.medium"
    xlarge = "t3a.large"
    # Smoke proves the stack starts; it does not measure. Collapses onto the
    # same type as xlarge, as it does in the measured profile above.
    xxlarge-mem = "t3a.large"
  }
}

variable "root_volume_type" {
  type        = string
  default     = "gp3"
  description = "EBS volume type for root volumes."
}

variable "root_volume_iops" {
  type        = number
  default     = 3000
  description = "Provisioned IOPS. gp3's 3000 baseline bottlenecks the database role well before CPU does; raise it for disk-bound benchmarks rather than accepting the default silently."
}

variable "root_volume_throughput" {
  type        = number
  default     = 125
  description = "EBS throughput in MiB/s."
}

variable "placement_group_strategy" {
  type        = string
  default     = "cluster"
  description = "Placement strategy for the benchmark profile. 'cluster' packs instances for consistent low inter-node latency, which a distributed benchmark depends on. No placement group is created under the smoke profile: burstable types do not support cluster placement, and a wiring test does not need latency guarantees."
}

# The base image, pinned. AWS is where the campaigns run, so it is the one
# provider where an image change lands on live results rather than on a test
# bed -- and an image change is silent: every play succeeds, the lab collects,
# and the numbers describe a different kernel, sysctl baseline and libc.
#
# This replaced a data source reading the SSM alias below, which resolved to
# whatever Canonical had most recently published. That was a deliberate choice
# for portability over pinning; two things answer it. The lab is already
# region-bound -- all subnets live in one availability zone because an ENI is
# bound to one -- so a region-bound AMI costs nothing it has not already paid.
# And "rots" assumes nobody bumps the pin, which stopped being true of anything
# else in this repository.
#
# Resolve the current value with the alias this replaced:
#
#   aws ssm get-parameter --region <region> \
#     --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
#     --query Parameter.Value --output text
#
# Pinned value is what that returned on 2026-08-26, so pinning changed nothing
# about what deploys:
#   ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20260714
#   created 2026-07-14, owner 099720109477 (Canonical)
#
# An AMI ID is region-specific. Changing `region` without changing this fails
# the precondition in main.tf rather than failing obscurely at instance launch.
variable "ami_id" {
  type        = string
  default     = "ami-052355af2a014bd2c"
  description = "Ubuntu 24.04 AMI, pinned so the benchmark substrate does not move between campaigns. Region-specific; see ami_ssm_parameter for how to resolve a new value."
}

variable "ami_ssm_parameter" {
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
  description = "SSM public parameter resolving the current Ubuntu 24.04 AMI. No longer selects the image -- ami_id does. Kept as the documented way to find the value to pin, and to prove a pinned AMI is a real Canonical image."
}
