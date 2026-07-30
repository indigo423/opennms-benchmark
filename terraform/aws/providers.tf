# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region

  # A lab is cheap to rebuild and a production account is not. Pinning this
  # means an exported profile for the wrong account fails immediately instead of
  # provisioning a VPC beside something that matters.
  allowed_account_ids = length(var.allowed_account_ids) > 0 ? var.allowed_account_ids : null

  default_tags {
    tags = {
      project     = var.project_name
      environment = var.environment
      deployment  = var.deployment
      managed-by  = "terraform"
    }
  }
}
