variable "project_name" {
  description = "Prefix used for resource names and tags."
  type        = string
  default     = "task2-barq"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "app_private_ip" {
  description = "Fixed private IP of the app host (must be inside subnet_cidr)."
  type        = string
  default     = "10.20.1.10"
}

variable "db_private_ip" {
  description = "Fixed private IP of the database host (must be inside subnet_cidr)."
  type        = string
  default     = "10.20.1.20"
}

variable "app_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "db_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB) for both instances."
  type        = number
  default     = 20
}

variable "admin_cidr" {
  description = "Trusted IP in CIDR form for SSH, e.g. 203.0.113.10/32. Empty = detect the current public IP automatically."
  type        = string
  default     = ""

  validation {
    condition     = var.admin_cidr == "" || (can(cidrnetmask(var.admin_cidr)) && var.admin_cidr != "0.0.0.0/0")
    error_message = "admin_cidr must be empty or a valid CIDR, and must not be 0.0.0.0/0."
  }
}

variable "ssh_private_key_path" {
  description = "Your SSH private key. The public key is <path>.pub and is uploaded as the EC2 key pair."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_user" {
  description = "Default login user of the AMI (ubuntu for Ubuntu)."
  type        = string
  default     = "ubuntu"
}
variable "ubuntu_ami_id" {
  description = "Pinned Ubuntu 24.04 AMD64 AMI ID for the selected AWS region."
  type        = string
}
