# CubeMart Backend Notes

This repository is set up for a fresh `CubeMart` deployment and already uses
CubeMart-native Terraform backend identifiers.

## Current Backend Identifiers

- S3 bucket: `cubemart-infra-statefile-backup`
- DynamoDB lock table: `cubemart-terraform-locks`
- S3 state keys:
  - `cubemart/1-network/terraform.tfstate`
  - `cubemart/2-eks/terraform.tfstate`

## Related Files

- `0-bootstrap/main.tf`
- `1-network/backend.tf`
- `2-eks/backend.tf`
- `2-eks/data.tf`
- `Jenkinsfile`

## Fresh Setup Notes

- Apply `0-bootstrap` first to create the backend resources.
- Then initialize and apply `1-network`.
- Finally initialize and apply `2-eks`.

Because this project has not been deployed yet, there is no legacy Terraform
state migration required.
