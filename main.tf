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

# Public Subnet 1 (for ALB and ASG)
resource "aws_subnet" "mtc_public_subnet_1" {
  vpc_id                  = aws_vpc.mtc_vpc.id
  cidr_block              = "10.123.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "mtc-public-subnet-1"
  }
}

# Public Subnet 2 (ALB requires at least 2 AZs)
resource "aws_subnet" "mtc_public_subnet_2" {
  vpc_id                  = aws_vpc.mtc_vpc.id
  cidr_block              = "10.123.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "mtc-public-subnet-2"
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

# Route Table Associations
resource "aws_route_table_association" "public_assoc_1" {
  subnet_id      = aws_subnet.mtc_public_subnet_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_assoc_2" {
  subnet_id      = aws_subnet.mtc_public_subnet_2.id
  route_table_id = aws_route_table.public.id
}

# Security Group for ALB
resource "aws_security_group" "mtc_alb_sg" {
  name        = "mtc-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.mtc_vpc.id

  # HTTP access from internet
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS access from internet
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
    Name = "mtc-alb-security-group"
  }
}

# Security Group for EC2 instances (updated for ASG)
resource "aws_security_group" "mtc_instance_sg" {
  name        = "mtc-instance-sg"
  description = "Security group for EC2 instances in ASG"
  vpc_id      = aws_vpc.mtc_vpc.id

  # SSH access (restrict to your IP for security)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Consider restricting this to your IP
  }

  # HTTP access from ALB only
  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.mtc_alb_sg.id]
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "mtc-instance-security-group"
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

# Launch Template for Auto Scaling Group
resource "aws_launch_template" "mtc_launch_template" {
  name_prefix   = "mtc-launch-template-"
  description   = "Launch template for MTC Auto Scaling Group"
  image_id      = data.aws_ami.server_ami.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.mtc_auth.key_name

  vpc_security_group_ids = [aws_security_group.mtc_instance_sg.id]

  user_data = base64encode(file("userdata.tpl"))

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 8
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "mtc-asg-instance"
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "mtc-launch-template"
  }
}

# Application Load Balancer
resource "aws_lb" "mtc_alb" {
  name               = "mtc-application-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.mtc_alb_sg.id]
  subnets           = [
    aws_subnet.mtc_public_subnet_1.id,
    aws_subnet.mtc_public_subnet_2.id
  ]

  enable_deletion_protection = false

  tags = {
    Name = "mtc-application-load-balancer"
  }
}

# ALB Target Group
resource "aws_lb_target_group" "mtc_tg" {
  name     = "mtc-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.mtc_vpc.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name = "mtc-target-group"
  }
}

# ALB Listener
resource "aws_lb_listener" "mtc_listener" {
  load_balancer_arn = aws_lb.mtc_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mtc_tg.arn
  }

  tags = {
    Name = "mtc-alb-listener"
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "mtc_asg" {
  name                = "mtc-auto-scaling-group"
  vpc_zone_identifier = [
    aws_subnet.mtc_public_subnet_1.id,
    aws_subnet.mtc_public_subnet_2.id
  ]
  target_group_arns   = [aws_lb_target_group.mtc_tg.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300

  min_size         = 1
  max_size         = 4
  desired_capacity = 2

  launch_template {
    id      = aws_launch_template.mtc_launch_template.id
    version = "$Latest"
  }

  # Instance refresh configuration
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "mtc-asg-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "dev"
    propagate_at_launch = true
  }
}

# Auto Scaling Policies
resource "aws_autoscaling_policy" "mtc_scale_up" {
  name                   = "mtc-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.mtc_asg.name
}

resource "aws_autoscaling_policy" "mtc_scale_down" {
  name                   = "mtc-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.mtc_asg.name
}

# CloudWatch Alarms for Auto Scaling
resource "aws_cloudwatch_metric_alarm" "mtc_cpu_high" {
  alarm_name          = "mtc-cpu-utilization-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "70"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.mtc_scale_up.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.mtc_asg.name
  }
}

resource "aws_cloudwatch_metric_alarm" "mtc_cpu_low" {
  alarm_name          = "mtc-cpu-utilization-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "30"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.mtc_scale_down.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.mtc_asg.name
  }
}

resource "aws_instance" "dev_node" {
  instance_type          = "t3.micro"
  ami                    = data.aws_ami.server_ami.id
  # key_name               = aws_key_pair.mtc_auth.key_name
  vpc_security_group_ids = [aws_security_group.mtc_instance_sg.id]
  subnet_id              = aws_subnet.mtc_public_subnet_1.id
  user_data              = file("userdata.tpl")

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "mtc-dev-node-standalone"
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

output "public_subnet_1_id" {
  description = "ID of the first public subnet"
  value       = aws_subnet.mtc_public_subnet_1.id
}

output "public_subnet_2_id" {
  description = "ID of the second public subnet"
  value       = aws_subnet.mtc_public_subnet_2.id
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.mtc_alb.dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the Application Load Balancer"
  value       = aws_lb.mtc_alb.zone_id
}

output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.mtc_asg.name
}

output "launch_template_id" {
  description = "ID of the Launch Template"
  value       = aws_launch_template.mtc_launch_template.id
}

output "instance_id" {
  description = "ID of the standalone EC2 instance"
  value       = aws_instance.dev_node.id
}

output "instance_public_ip" {
  description = "Public IP address of the standalone EC2 instance"
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

output "ssh_command_standalone" {
  description = "SSH command to connect to the standalone instance"
  value       = "ssh -i ~/.ssh/mykey ec2-user@${aws_instance.dev_node.public_ip}"
}

output "application_url" {
  description = "URL to access the application via ALB"
  value       = "http://${aws_lb.mtc_alb.dns_name}"
}