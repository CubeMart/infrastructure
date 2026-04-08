data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "cubemart-infra-statefile-backup"
    key    = "cubemart/1-network/terraform.tfstate"
    region = "ap-northeast-1"
  }
}
