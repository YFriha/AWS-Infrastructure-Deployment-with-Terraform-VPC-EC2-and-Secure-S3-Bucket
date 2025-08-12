# Generate random suffix for unique bucket naming
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Data source to fetch the latest Amazon Linux 2 AMI
data "aws_ami" "server_ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Get available availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# VPC Configuration
resource "aws_vpc" "mtc_vpc" {
  cidr_block           = "10.123.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "mtc-vpc"
  }
}

# Public Subnet
resource "aws_subnet" "mtc_public_subnet" {
  vpc_id                  = aws_vpc.mtc_vpc.id
  cidr_block              = "10.123.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "mtc-public-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "mtc_igw" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "mtc-igw"
  }
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "mtc-public-rt"
  }
}

# Default Route for Internet Access
resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.mtc_igw.id
}

# Route Table Association
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.mtc_public_subnet.id
  route_table_id = aws_route_table.public.id
}

# Security Group with Restricted Access
resource "aws_security_group" "mtc_sg" {
  name        = "mtc-public-sg"
  description = "Security group for public instances"
  vpc_id      = aws_vpc.mtc_vpc.id

  # SSH access (more secure - restrict to your IP)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  # HTTP access
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS access
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "mtc-security-group"
  }
}

# Key Pair for EC2 Access
resource "aws_key_pair" "mtc_auth" {
  key_name   = "mykey"
  public_key = file("~/.ssh/mykey.pub")

  tags = {
    Name = "mtc-keypair"
  }
}

# EC2 Instance
resource "aws_instance" "dev_node" {
  instance_type          = "t3.micro"
  ami                    = data.aws_ami.server_ami.id
  # key_name               = aws_key_pair.mtc_auth.key_name
  vpc_security_group_ids = [aws_security_group.mtc_sg.id]
  subnet_id              = aws_subnet.mtc_public_subnet.id
  user_data              = file("userdata.tpl")

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "mtc-dev-node2"
  }

  provisioner "local-exec" {
    command = templatefile("ssh-config.tpl", {
      hostname      = self.public_ip,
      user          = "ec2-user",
      identity_file = "~/.ssh/mykey"
    })
    interpreter = ["PowerShell", "-Command"]
  }
}

# S3 Bucket with Secure Configuration
resource "aws_s3_bucket" "mtc_bucket" {
  bucket        = "mtc-bucket-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "mtc-bucket"
    Environment = "dev"
  }
}

# S3 Bucket Versioning
resource "aws_s3_bucket_versioning" "mtc_bucket_versioning" {
  bucket = aws_s3_bucket.mtc_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket Server-Side Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "mtc_bucket_encryption" {
  bucket = aws_s3_bucket.mtc_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 Bucket Public Access Block
resource "aws_s3_bucket_public_access_block" "mtc_bucket_pab" {
  bucket = aws_s3_bucket.mtc_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Bucket ACL
resource "aws_s3_bucket_acl" "mtc_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.mtc_bucket_acl_ownership]
  
  bucket = aws_s3_bucket.mtc_bucket.id
  acl    = "private"
}

# S3 Bucket Ownership Controls
resource "aws_s3_bucket_ownership_controls" "mtc_bucket_acl_ownership" {
  bucket = aws_s3_bucket.mtc_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# S3 Object - SSH Public Key (stored securely)
resource "aws_s3_object" "mtc_ssh_key" {
  bucket       = aws_s3_bucket.mtc_bucket.id
  key          = "keys/mykey.pub"
  source       = "~/.ssh/mykey.pub"
  content_type = "text/plain"
  
  tags = {
    Name        = "mtc-ssh-key"
    Type        = "ssh-public-key"
    Environment = "dev"
  }
}

# Outputs
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.mtc_vpc.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.mtc_public_subnet.id
}

output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.dev_node.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.dev_node.public_ip
}

output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.mtc_bucket.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.mtc_bucket.arn
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/mykey ec2-user@${aws_instance.dev_node.public_ip}"
}