terraform {
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.24, < 7.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}