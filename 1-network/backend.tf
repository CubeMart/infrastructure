terraform {
  backend "s3" {
    bucket         = "cubemart-infra-statefile-backup"
    key            = "cubemart/1-network/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "cubemart-terraform-locks"
    encrypt        = true
  }
}
