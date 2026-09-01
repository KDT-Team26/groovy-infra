terraform {
  backend "s3" {
    bucket       = "groovy-terraform-state-665206375378-ap-northeast-2"
    key          = "groovy/dev/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}