terraform {
  backend "s3" {
    bucket         = "cubemart-infra-statefile-backup"
    key            = "cubemart/2-eks/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "cubemart-terraform-locks"
    encrypt        = true
  }
}
