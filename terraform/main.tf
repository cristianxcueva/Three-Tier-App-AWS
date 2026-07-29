terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "three-tier-vpc"
  }
}

# Public Subnets
resource "aws_subnet" "public_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "public-subnet-1"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "public-subnet-2"
  }
}

# Private Subnets
resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "private-subnet-1"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "private-subnet-2"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "three-tier-igw"
  }
}

# ALB sits in front of EC2 - needs its own SG separate from backend
# Port 80 open to internet, all outbound allowed to reach EC2 instances
resource "aws_security_group" "alb" {
  name        = "three-tier-alb-sg"
  description = "Allow HTTP traffic to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "three-tier-alb-sg"
  }
}

# ALB distributes traffic across EC2 instances in both public subnets
# internet facing so it has a public DNS name users can reach

resource "aws_lb" "main" {
  name               = "three-tier-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = {
    Name = "three-tier-alb"
  }
}

# Target group is where ALB sends traffic - EC2 instances register here
# health check on / confirms the Node.js server is actually responding

resource "aws_lb_target_group" "main" {
  name     = "three-tier-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    port                = 8080
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
  }

  tags = {
    Name = "three-tier-tg"
  }
}

# Listener on port 80 - receives incoming traffic and forwards to target group
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-route-table"
  }
}

# Associate Public Subnets with Route Table
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# Secrets Manager - DB Credentials
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "three-tier-db-credentials"
  recovery_window_in_days = 0

  tags = {
    Name = "three-tier-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "dbadmin"
    password = "ReplaceThisWithSomethingStrong123!"
  })
}

# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "three-tier-db-subnet-group"
  subnet_ids = [aws_subnet.private_1.id, aws_subnet.private_2.id]

  tags = {
    Name = "three-tier-db-subnet-group"
  }
}

# Security Group - RDS
resource "aws_security_group" "rds" {
  name        = "three-tier-rds-sg"
  description = "Allow PostgreSQL traffic from backend only"
  vpc_id      = aws_vpc.main.id

  ingress {
  from_port       = 5432
  to_port         = 5432
  protocol        = "tcp"
  security_groups = [aws_security_group.backend.id]
}

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "three-tier-rds-sg"
  }
}

# RDS Instance
resource "aws_db_instance" "main" {
  identifier        = "three-tier-db"
  engine            = "postgres"
  engine_version    = "15.7"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = "threetierdb"
  username = "dbadmin"
  password = "ReplaceThisWithSomethingStrong123!"

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot = true
  backup_retention_period = 7
  multi_az = true
  publicly_accessible = false
  
  tags = {
    Name = "three-tier-db"
  }
}

# Security Group - EC2 Backend
 # Port 8080 locked to ALB only - direct internet access to EC2 removed
  # once ALB sits in front, no reason for the world to reach EC2 directly
resource "aws_security_group" "backend" {
  name        = "three-tier-backend-sg"
  description = "Allow SSH and HTTP traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "three-tier-backend-sg"
  }
}

# IAM Role - EC2
resource "aws_iam_role" "ec2_role" {
  name = "three-tier-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "three-tier-ec2-role"
  }
}

# IAM Policy - Secrets Manager Access
resource "aws_iam_role_policy" "secrets_access" {
  name = "three-tier-secrets-access"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "three-tier-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Launch template replaces the single aws_instance - ASG uses this as the
# blueprint for every EC2 it creates, same config as the original instance
resource "aws_launch_template" "backend" {
  name_prefix   = "three-tier-backend-"
  image_id      = "ami-0521cb2d60cfbb1a6"
  instance_type = "t3.micro"
  key_name      = "three-tier-key"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

 vpc_security_group_ids = [aws_security_group.backend.id]

 # Same user_data as the original instance - installs Node.js and starts
  # the API on port 8080, runs automatically on every new instance launch
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y nodejs npm
    mkdir -p /app
    cat > /app/server.js << 'SCRIPT'
    const http = require('http');
    const server = http.createServer((req, res) => {
      res.writeHead(200, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({ message: 'Backend is alive', status: 'ok' }));
    });
    server.listen(8080, () => console.log('Server running on port 8080'));
    SCRIPT
    node /app/server.js &
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "three-tier-backend"
    }
  }
}

# ASG manages EC2 instances across both public subnets - min 1 keeps something
# always running, desired 2 proves multi-AZ HA, max 3 allows scaling headroom
resource "aws_autoscaling_group" "backend" {
  name                      = "three-tier-asg"
  desired_capacity          = 2
  min_size                  = 1
  max_size                  = 3
  vpc_zone_identifier       = [aws_subnet.public_1.id, aws_subnet.public_2.id]
  target_group_arns         = [aws_lb_target_group.main.arn]

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "three-tier-backend"
    propagate_at_launch = true
  }
}

# S3 Bucket - Frontend
resource "aws_s3_bucket" "frontend" {
  bucket = "three-tier-frontend-${random_id.bucket_suffix.hex}"

  tags = {
    Name = "three-tier-frontend"
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Block all public access - CloudFront only
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Origin Access Control - allows CloudFront to access private S3
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "three-tier-oac"
  description                       = "OAC for three tier frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "frontend" {
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "three-tier-frontend"
  }
}

# S3 Bucket Policy - allow CloudFront access only
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontAccess"
        Effect    = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      }
    ]
  })
}

# Outputs
output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "DNS name of the backend ALB"
}

output "cloudfront_url" {
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
  description = "CloudFront URL for the frontend"
}

output "rds_endpoint" {
  value       = aws_db_instance.main.endpoint
  description = "RDS endpoint for the database"
}

# Upload frontend to S3
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content      = templatefile("../frontend/index.html", {
    backend_url = aws_lb.main.dns_name
  })
  content_type = "text/html"
  etag         = md5(templatefile("../frontend/index.html", {
    backend_url = aws_lb.main.dns_name
  }))
}

# CloudWatch Alarm - EC2 CPU
resource "aws_cloudwatch_metric_alarm" "ec2_cpu" {
  alarm_name          = "three-tier-ec2-cpu-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "EC2 CPU utilization exceeded 80%"

  dimensions = {
    AutoscalingGroupName = aws_autoscaling_group.backend.name
  }

  tags = {
    Name = "three-tier-ec2-cpu-alarm"
  }
}