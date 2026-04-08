# CubeMart Infrastructure

This repository provisions the AWS infrastructure for CubeMart using Terraform, organized into layered modules and automated through a Jenkins CI/CD pipeline.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Layer 0 — Bootstrap](#layer-0--bootstrap)
- [Layer 1 — Network](#layer-1--network)
- [Layer 2 — EKS](#layer-2--eks)
- [Remote State & Locking](#remote-state--locking)
- [Backend Configuration](#backend-configuration)
- [Jenkins Pipeline](#jenkins-pipeline)
- [Jenkins Setup Requirements](#jenkins-setup-requirements)
- [Execution Flow](#execution-flow)
- [Destroy Order](#destroy-order)

---

## Architecture Overview

```
                     AWS Account (ap-northeast-1)

  ┌─────────────────────────────────────────────────────────┐
  │                     VPC: 10.0.0.0/16                    │
  │                                                         │
  │   ┌─────────────────────┐   ┌─────────────────────┐    │
  │   │  Public Subnet AZ-a │   │  Public Subnet AZ-b │    │
  │   │   10.0.0.0/24       │   │   10.0.1.0/24       │    │
  │   │  [ALB] [NAT GW]     │   │                     │    │
  │   └─────────────────────┘   └─────────────────────┘    │
  │              |                                          │
  │   ┌─────────────────────┐   ┌─────────────────────┐    │
  │   │  Private Subnet AZ-a│   │  Private Subnet AZ-b│    │
  │   │   10.0.10.0/24      │   │   10.0.11.0/24      │    │
  │   │  [EKS Nodes]        │   │  [EKS Nodes]        │    │
  │   └─────────────────────┘   └─────────────────────┘    │
  └─────────────────────────────────────────────────────────┘

  S3 Bucket         → cubemart-infra-statefile-backup
  DynamoDB Table    → cubemart-terraform-locks
  EKS Cluster       → cubemart
```

---

## Project Structure

```
InfraStructure/
├── 0-bootstrap/                  # Remote backend (S3 + DynamoDB)
│   ├── main.tf
│   ├── providers.tf
│   └── outputs.tf
│
├── 1-network/                    # VPC, Subnets, NAT, IGW
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── backend.tf
│
├── 2-eks/                        # EKS Cluster + Node Group
│   ├── main.tf
│   ├── data.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── backend.tf
│
├── Jenkinsfile                   # CI/CD pipeline
└── README.md
```

> Layers are numbered intentionally. They must run in order because each layer depends on the previous one.

---

## Layer 0 — Bootstrap

### Purpose
Creates the remote backend infrastructure that all other layers use to store their Terraform state files. This layer runs **once** and its own state is stored locally.

### Resources

| Resource | Name | Purpose |
|---|---|---|
| `aws_s3_bucket` | `cubemart-infra-statefile-backup` | Stores all `.tfstate` files remotely |
| `aws_s3_bucket_versioning` | same bucket | Keeps history of state — allows rollback |
| `aws_s3_bucket_server_side_encryption_configuration` | same bucket | Encrypts state files at rest (AES256) |
| `aws_s3_bucket_public_access_block` | same bucket | Blocks all public access to state files |
| `aws_dynamodb_table` | `cubemart-terraform-locks` | Prevents concurrent terraform applies |

### Why This Runs First
Layers 1 and 2 both declare an S3 backend. The bucket and DynamoDB table **must already exist** before `terraform init` can run on those layers. Bootstrap creates them.

### Outputs

| Output | Value |
|---|---|
| `tf_state_bucket` | Name of the S3 bucket |
| `tf_lock_table` | Name of the DynamoDB table |

---

## Layer 1 — Network

### Purpose
Creates the VPC and all networking components that the EKS cluster will live inside.

### Resources

| Resource | Purpose |
|---|---|
| `aws_vpc` | Isolated network — CIDR `10.0.0.0/16` |
| `aws_internet_gateway` | Allows public subnets to reach the internet |
| `aws_subnet` (public x2) | For ALB and NAT Gateway |
| `aws_subnet` (private x2) | For EKS worker nodes |
| `aws_eip` | Static IP assigned to the NAT Gateway |
| `aws_nat_gateway` | Allows private subnets to reach internet (outbound only) |
| `aws_route_table` (public) | Routes `0.0.0.0/0` → Internet Gateway |
| `aws_route_table` (private) | Routes `0.0.0.0/0` → NAT Gateway |

### Subnet Layout

```
VPC: 10.0.0.0/16
├── Public Subnet AZ-a   10.0.0.0/24    ← ALB, NAT Gateway
├── Public Subnet AZ-b   10.0.1.0/24
├── Private Subnet AZ-a  10.0.10.0/24   ← EKS worker nodes
└── Private Subnet AZ-b  10.0.11.0/24   ← EKS worker nodes
```

> EKS nodes are placed in **private subnets** — they are not directly reachable from the internet. The NAT Gateway allows outbound traffic (pulling images, updates) from private subnets.

### Kubernetes Tags

Subnets are tagged so the AWS Load Balancer Controller can auto-discover them:

```hcl
# Public subnets
"kubernetes.io/role/elb"               = "1"
"kubernetes.io/cluster/cubemart"  = "shared"

# Private subnets
"kubernetes.io/role/internal-elb"      = "1"
"kubernetes.io/cluster/cubemart"  = "shared"
```

### Variables

| Variable | Default | Description |
|---|---|---|
| `project` | `cubemart` | Used in all resource names and tags |
| `vpc_cidr` | `10.0.0.0/16` | CIDR block for the VPC |
| `azs` | `["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]` | Availability zones to deploy into |

### Outputs

| Output | Description |
|---|---|
| `vpc_id` | VPC ID consumed by Layer 2 |
| `public_subnet_ids` | List of public subnet IDs |
| `private_subnet_ids` | List of private subnet IDs consumed by Layer 2 |

---

## Layer 2 — EKS

### Purpose
Creates the Kubernetes cluster and managed worker node group inside the network from Layer 1.

### How It Reads Layer 1 Outputs

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "cubemart-infra-statefile-backup"
    key    = "cubemart/1-network/terraform.tfstate"
    region = "ap-northeast-1"
  }
}
```

This pulls `vpc_id`, `private_subnet_ids`, and `public_subnet_ids` directly from Layer 1's saved state — no hardcoded values needed.

### EKS Cluster Configuration

| Setting | Value | Notes |
|---|---|---|
| `cluster_name` | `cubemart` | |
| `cluster_version` | `1.30` | Kubernetes version |
| `enable_irsa` | `true` | IAM Roles for Service Accounts |
| `cluster_endpoint_public_access` | `true` | `kubectl` works from your laptop |
| `cluster_endpoint_private_access` | `true` | Nodes communicate internally |

### Node Group

| Setting | Value |
|---|---|
| Instance type | `c7i-flex.large` |
| Min size | 1 |
| Max size | 3 |
| Desired size | 2 |
| Subnet | Private subnets |

### What is IRSA?

`enable_irsa = true` enables **IAM Roles for Service Accounts**. This allows Kubernetes pods to assume AWS IAM roles directly without hardcoding credentials. Required for:
- AWS Load Balancer Controller
- Cluster Autoscaler
- External DNS
- Any pod that needs AWS API access

### Outputs

| Output | Description |
|---|---|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | API server endpoint for `kubectl` |
| `cluster_certificate_authority_data` | Certificate data for authentication |
| `region` | AWS region (`ap-northeast-1`) |

---

## Remote State & Locking

### Why Remote State?

By default, Terraform stores state locally as `terraform.tfstate`. In a team or CI/CD environment this causes problems:
- Local files are not shared between team members or pipeline runs
- No history or versioning
- No protection against corruption

Storing state in S3 solves all of this.

### State File Locations

| Layer | S3 Key |
|---|---|
| 1-network | `cubemart/1-network/terraform.tfstate` |
| 2-eks | `cubemart/2-eks/terraform.tfstate` |

### Why DynamoDB Locking?

When two `terraform apply` runs happen at the same time (two developers, two pipeline triggers), they both read the same state file and start writing changes. This causes **state corruption**.

DynamoDB acts as a distributed lock:

```
Pipeline Run #1 starts apply
  → Acquires lock in DynamoDB (LockID written)
  → Makes infrastructure changes
  → Releases lock when done

Pipeline Run #2 starts at the same time
  → Tries to acquire lock
  → Lock already held by Run #1
  → Errors: "state is locked" — safely blocked

Run #1 finishes → lock released → Run #2 can proceed
```

---

## Backend Configuration

This repo is configured to use CubeMart-native Terraform backend identifiers
from the start:

- S3 bucket: `cubemart-infra-statefile-backup`
- DynamoDB table: `cubemart-terraform-locks`
- state keys:
  - `cubemart/1-network/terraform.tfstate`
  - `cubemart/2-eks/terraform.tfstate`

If you are starting fresh, no legacy backend migration is required.

DynamoDB table used across all layers: `cubemart-terraform-locks`

---

## Jenkins Pipeline

### Overview

The pipeline has a **single approval gate** — all three layers are planned first, you review everything at once, then execution proceeds layer by layer.

```
Checkout
    ↓
Plan: All Layers   (0-bootstrap + 1-network + 2-eks)
    ↓
★ APPROVAL — Human reviews combined plan output ★
    ↓
Execute: 0-bootstrap
    ↓
Execute: 1-network
    ↓
Execute: 2-eks
```

### Parameters

| Parameter | Options | Description |
|---|---|---|
| `terraformAction` | `apply` / `destroy` | Action to perform on all layers |

### Stage Breakdown

#### Checkout
Clones the repository from the `terraform` branch into a `terraform/` subdirectory on the Jenkins agent.

#### Plan: All Layers
Runs the following on each layer sequentially — **no infrastructure is changed**:
```
terraform init   → downloads providers, configures S3 backend
terraform plan   → calculates changes, saves binary plan to tfplan
terraform show   → converts tfplan to human-readable tfplan.txt
```

#### Approval
Pipeline pauses and waits for a human to review. The combined plan output of all 3 layers is shown together.
- Click **Proceed** → execution begins
- Click **Abort** → pipeline stops, nothing is applied

#### Execute Layers
Each layer runs one at a time and waits for the previous to fully complete:
- `apply` → uses the saved `tfplan` so exactly what was reviewed gets applied
- `destroy` → runs `terraform destroy -auto-approve`

---

## Jenkins Setup Requirements

### 1. Jenkins Credentials

Go to **Manage Jenkins → Credentials** and add:

| ID | Type | Value |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Secret Text | Your AWS Access Key ID |
| `AWS_SECRET_ACCESS_KEY` | Secret Text | Your AWS Secret Access Key |

### 2. Required Jenkins Plugins

| Plugin | Purpose |
|---|---|
| Pipeline | Run declarative pipelines |
| Git | Checkout from GitHub |
| Credentials Binding | Inject AWS credentials securely |

### 3. Terraform on Jenkins Agent

Terraform must be installed on the Jenkins agent and available in `PATH`:

```bash
# Verify
terraform -version
```

### 4. AWS IAM Permissions

The IAM user or role used by Jenkins needs permissions for:

| Service | Permissions Needed |
|---|---|
| S3 | CreateBucket, PutObject, GetObject, ListBucket |
| DynamoDB | CreateTable, PutItem, GetItem, DeleteItem |
| VPC | Full VPC permissions |
| EKS | Full EKS permissions |
| EC2 | Full EC2 permissions (for node groups) |
| IAM | CreateRole, AttachRolePolicy (for IRSA) |

---

## Execution Flow

### Apply (First Time)

```bash
# Step 1 — Run bootstrap manually once to create S3 + DynamoDB
cd 0-bootstrap
terraform init
terraform apply

# Step 2 — Trigger the Jenkins pipeline with action: apply
# Pipeline handles 1-network and 2-eks automatically
```

### Day-to-Day

1. Go to Jenkins → trigger **Build with Parameters**
2. Select `apply` or `destroy`
3. Wait for the **Plan** stage to complete
4. Review the combined plan in the **Approval** stage
5. Click **Proceed** to apply

---

## Destroy Order

> **Important:** Always destroy in reverse order — EKS first, then Network, then Bootstrap.

Destroying in forward order will fail because resources are still in use (e.g., you cannot delete a VPC while EKS nodes are still running inside it).

```
Destroy: 2-eks        → removes EKS cluster and nodes first
    ↓
Destroy: 1-network    → removes VPC, subnets, NAT after nodes are gone
    ↓
Destroy: 0-bootstrap  → removes S3 bucket and DynamoDB last
```

---

## Quick Reference

| Item | Value |
|---|---|
| AWS Region | `ap-northeast-1` |
| Project Name | `cubemart` |
| EKS Cluster | `cubemart` |
| Kubernetes Version | `1.30` |
| VPC CIDR | `10.0.0.0/16` |
| Availability Zones | `ap-northeast-1a`, `ap-northeast-1c`, `ap-northeast-1d` |
| S3 State Bucket | `cubemart-infra-statefile-backup` |
| DynamoDB Lock Table | `cubemart-terraform-locks` |
| Node Instance Type | `c7i-flex.large` |
| Node Count | min: 1, desired: 2, max: 3 |
