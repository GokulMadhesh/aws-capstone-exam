############################################
# Provider + Variables (single-file style)
############################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "StreamLine-Capstone"
      Environment = "Production"
      ManagedBy   = "Terraform"
    }
  }
}

# Choose two AZs
variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

# Ubuntu AMI (us-east-1) - verify this AMI exists in your account/region
variable "ubuntu_ami" {
  type    = string
  default = "ami-0b6c6ebed2801a5cb"
}

# Optional: your public IP for SSH (recommended instead of 0.0.0.0/0)
# Example value: "49.204.xxx.xxx/32"
variable "ssh_cidr" {
  type        = string
  description = "CIDR allowed to SSH into EC2 instances (use your public IP /32)"
  default     = "0.0.0.0/0"
}

############################################
# Use default VPC + select default public subnets
############################################

data "aws_vpc" "default" {
  default = true
}

# Default-for-az subnets are AWS-created default public subnets
data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Pick two public subnets (sorted for stability)
locals {
  selected_public_subnet_ids = slice(sort(data.aws_subnets.default_public.ids), 0, 2)
}

############################################
# Two NEW private subnets for RDS (no internet)
############################################

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = cidrsubnet(data.aws_vpc.default.cidr_block, 8, count.index + 100)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "streamline-private-${count.index + 1}"
  }
}

resource "aws_route_table" "private_rt" {
  vpc_id = data.aws_vpc.default.id

  tags = {
    Name = "streamline-private-rt"
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private_rt.id
}

############################################
# Security Groups
############################################

# Security group for the ALB (internet-facing)
resource "aws_security_group" "alb_sg" {
  name        = "streamline-alb-sg"
  description = "Allow HTTP from anywhere to ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
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
    Name = "streamline-alb-sg"
  }
}

# Security group for web instances (allow HTTP ONLY from ALB; SSH from your IP)
resource "aws_security_group" "web_sg" {
  name        = "streamline-web-sg"
  description = "Allow HTTP from ALB and SSH from allowed CIDR"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "streamline-web-sg"
  }
}

# DB SG allows MySQL from web instances only
resource "aws_security_group" "db_sg" {
  name        = "streamline-db-sg"
  description = "Allow MySQL from web SG only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL from web"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "streamline-db-sg"
  }
}

############################################
# RDS: Subnet group + MySQL instance
############################################

resource "aws_db_subnet_group" "db_subnets" {
  name       = "streamline-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "streamline-db-subnet-group"
  }
}

resource "aws_db_instance" "mysql" {
  identifier             = "streamline-db"
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"

  username               = "admin"
  password               = "Password123!" # Demo only; do not use in real projects

  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false
  deletion_protection    = false

  tags = {
    Name = "streamline-rds"
  }
}

############################################
# Two Web EC2 instances
############################################

# NOTE: key_name must exist in AWS EC2 Key Pairs (us-east-1)
variable "key_name" {
  type        = string
  description = "Existing EC2 key pair name in us-east-1"
  default     = "02-06-2026-Nvirginia"
}

resource "aws_instance" "web" {
  count                       = 2
  ami                         = var.ubuntu_ami
  instance_type               = "t3.micro"
  subnet_id                   = local.selected_public_subnet_ids[count.index]
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true
  key_name                    = var.key_name

  tags = {
    Name = "streamline-web-${count.index + 1}"
  }
}

############################################
# ALB + Target Group + Listener
############################################

resource "aws_lb" "app_lb" {
  name               = "streamline-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = local.selected_public_subnet_ids
  security_groups    = [aws_security_group.alb_sg.id]

  tags = {
    Name = "streamline-alb"
  }
}

resource "aws_lb_target_group" "tg" {
  name     = "streamline-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = {
    Name = "streamline-tg"
  }
}

resource "aws_lb_target_group_attachment" "attach" {
  count            = 2
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

############################################
# Outputs
############################################

output "alb_dns_name" {
  value = aws_lb.app_lb.dns_name
}

output "web_public_ips" {
  value = aws_instance.web[*].public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}
