terraform {
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.24, < 7.0"
    }
  }

  backend "s3" {
    bucket       = "groovy-terraform-state-665206375378-ap-northeast-2"
    key          = "groovy/dev/frontend-cdn.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}