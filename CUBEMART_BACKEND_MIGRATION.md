# CubeMart Backend Migration Plan

This document describes the safest way to rename the remaining legacy
`quantamvector-*` Terraform backend identifiers to `cubemart-*` without
breaking state access, locking, or Terraform automation.

## Scope

Current backend identifiers:

- S3 bucket: `quantamvector-infra-statefile-backup`
- DynamoDB lock table: `quantamvector-terraform-locks`
- S3 state keys:
  - `quantamvector/1-network/terraform.tfstate`
  - `quantamvector/2-eks/terraform.tfstate`

Target backend identifiers:

- S3 bucket: `cubemart-infra-statefile-backup`
- DynamoDB lock table: `cubemart-terraform-locks`
- S3 state keys:
  - `cubemart/1-network/terraform.tfstate`
  - `cubemart/2-eks/terraform.tfstate`

## Files That Will Change

- `0-bootstrap/main.tf`
- `1-network/backend.tf`
- `2-eks/backend.tf`
- `2-eks/data.tf`
- `1-network/variables.tf`
- `2-eks/variables.tf`
- `Jenkinsfile`

## Important Safety Rules

- Do not make these changes while another `terraform apply` is running.
- Do not rename the backend files first and "figure out the state later".
- Back up the current state before changing any backend configuration.
- Migrate backend names separately from changing the Terraform `project`
  default. Backend rename is lower risk than renaming the EKS/VPC resource
  identifier.

## Recommended Migration Order

### Phase 0: Freeze Changes

Pause:

- Jenkins Terraform jobs
- manual `terraform apply`
- any branch merges that could change infrastructure

### Phase 1: Back Up Existing State

Run from a safe terminal with AWS credentials for `ap-northeast-1`:

```bash
mkdir -p ~/cubemart-tf-backup

aws s3 cp \
  s3://quantamvector-infra-statefile-backup/quantamvector/1-network/terraform.tfstate \
  ~/cubemart-tf-backup/1-network.tfstate

aws s3 cp \
  s3://quantamvector-infra-statefile-backup/quantamvector/2-eks/terraform.tfstate \
  ~/cubemart-tf-backup/2-eks.tfstate
```

Optional extra backup:

```bash
aws s3 sync \
  s3://quantamvector-infra-statefile-backup \
  ~/cubemart-tf-backup/s3-backup
```

### Phase 2: Create the New Backend Resources

Create the new S3 bucket:

```bash
aws s3api create-bucket \
  --bucket cubemart-infra-statefile-backup \
  --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1
```

Enable versioning:

```bash
aws s3api put-bucket-versioning \
  --bucket cubemart-infra-statefile-backup \
  --versioning-configuration Status=Enabled
```

Enable default encryption:

```bash
aws s3api put-bucket-encryption \
  --bucket cubemart-infra-statefile-backup \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }
    ]
  }'
```

Block public access:

```bash
aws s3api put-public-access-block \
  --bucket cubemart-infra-statefile-backup \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'
```

Create the new lock table:

```bash
aws dynamodb create-table \
  --region ap-northeast-1 \
  --table-name cubemart-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Wait for the table to exist:

```bash
aws dynamodb wait table-exists \
  --region ap-northeast-1 \
  --table-name cubemart-terraform-locks
```

### Phase 3: Copy State Files to the New Backend

```bash
aws s3 cp \
  s3://quantamvector-infra-statefile-backup/quantamvector/1-network/terraform.tfstate \
  s3://cubemart-infra-statefile-backup/cubemart/1-network/terraform.tfstate

aws s3 cp \
  s3://quantamvector-infra-statefile-backup/quantamvector/2-eks/terraform.tfstate \
  s3://cubemart-infra-statefile-backup/cubemart/2-eks/terraform.tfstate
```

Verify the new state objects exist:

```bash
aws s3 ls s3://cubemart-infra-statefile-backup/cubemart/1-network/terraform.tfstate
aws s3 ls s3://cubemart-infra-statefile-backup/cubemart/2-eks/terraform.tfstate
```

### Phase 4: Update Terraform Backend References

Update these files:

#### `0-bootstrap/main.tf`

```hcl
bucket = "cubemart-infra-statefile-backup"
name   = "cubemart-terraform-locks"
```

#### `1-network/backend.tf`

```hcl
bucket         = "cubemart-infra-statefile-backup"
key            = "cubemart/1-network/terraform.tfstate"
dynamodb_table = "cubemart-terraform-locks"
```

#### `2-eks/backend.tf`

```hcl
bucket         = "cubemart-infra-statefile-backup"
key            = "cubemart/2-eks/terraform.tfstate"
dynamodb_table = "cubemart-terraform-locks"
```

#### `2-eks/data.tf`

```hcl
bucket = "cubemart-infra-statefile-backup"
key    = "cubemart/1-network/terraform.tfstate"
```

#### `Jenkinsfile`

Update imports to:

```groovy
terraform import aws_s3_bucket.tf_state cubemart-infra-statefile-backup || true
terraform import aws_dynamodb_table.tf_lock cubemart-terraform-locks || true
```

### Phase 5: Reinitialize Terraform Safely

Run these commands locally before unfreezing Jenkins:

```bash
cd 1-network
terraform init -reconfigure
terraform state list
terraform plan
```

```bash
cd ../2-eks
terraform init -reconfigure
terraform state list
terraform plan
```

Expected result:

- `terraform init -reconfigure` succeeds
- `terraform state list` shows existing resources
- `terraform plan` does not propose unexpected replacement from backend drift

### Phase 6: Push and Re-enable Automation

Once local validation passes:

- commit the backend changes
- push to `main`
- re-enable Jenkins runs

## Rollback Plan

If anything fails after editing the backend config:

1. restore the old backend values in:
   - `1-network/backend.tf`
   - `2-eks/backend.tf`
   - `2-eks/data.tf`
   - `Jenkinsfile`
2. run:

```bash
cd 1-network
terraform init -reconfigure
```

```bash
cd ../2-eks
terraform init -reconfigure
```

3. confirm Terraform can still read the old state
4. keep using:
   - `quantamvector-infra-statefile-backup`
   - `quantamvector-terraform-locks`

Because the original state files are not deleted during migration, rollback is
straightforward as long as you keep the old bucket and old key paths intact.

## Separate Follow-Up: Renaming `project = "quantamvector"`

This is a separate change and should not be bundled into the backend rename.

Changing:

- `1-network/variables.tf`
- `2-eks/variables.tf`

from:

```hcl
default = "quantamvector"
```

to:

```hcl
default = "cubemart"
```

can affect:

- EKS cluster name
- node group name
- VPC and subnet tags
- Kubernetes auto-discovery tags

Treat that as a second migration with its own `terraform plan` review.
