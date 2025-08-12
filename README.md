# AWS Infrastructure Deployment with Terraform

This Terraform project automates the provisioning of a simple, secure AWS infrastructure.  
It creates a custom VPC with public subnet, an EC2 instance, and a securely configured S3 bucket with versioning and encryption.

---

## Components

- **VPC** with DNS support and hostname resolution
- **Public Subnet** configured to assign public IPs on launch
- **Internet Gateway** attached to VPC for internet access
- **Route Table** and association to allow outbound internet access from subnet
- **Security Group** allowing SSH, HTTP, and HTTPS access
- **EC2 Instance** (Amazon Linux 2) launched inside the public subnet with SSH key access
- **S3 Bucket** with:
  - Unique name generated with random suffix
  - Versioning enabled
  - Server-side encryption (AES256)
  - Public access blocked
  - Ownership controls set
- **S3 Object** storing your SSH public key securely inside the bucket

---

## Prerequisites

- Terraform installed (v1.0+ recommended)
- AWS CLI configured with proper credentials and profile (e.g. `TerraformUser`)
- SSH key pair (`~/.ssh/mykey` and `~/.ssh/mykey.pub`) created locally

---

## How to use

1. Clone this repository or copy the Terraform files to your working directory.
2. Initialize Terraform providers:
   ```bash
   terraform init
3.Review the planned infrastructure changes:

    ```bash
    terraform plan

4.Apply the changes to provision infrastructure:

    ```bash
    terraform apply

After the deployment, use the output SSH command to connect to your EC2 instance:

    ```bash
    ssh -i ~/.ssh/mykey ec2-user@<instance_public_ip>
To destroy all resources when done:

      ```bash
      terraform destroy
Notes
The S3 bucket name includes a random suffix to avoid naming conflicts.

The EC2 instance uses the latest Amazon Linux 2 AMI.

The security group currently allows SSH from anywhere (0.0.0.0/0), which you may want to restrict to your IP for better security.

User data script (userdata.tpl) and SSH config template (ssh-config.tpl) are expected to be in the same folder as the Terraform files.

Outputs
VPC ID

Public subnet ID

EC2 instance ID and public IP

S3 bucket name and ARN

SSH connection command

