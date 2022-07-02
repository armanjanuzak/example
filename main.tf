provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  
  tags = {
    Name = "test"
  }
}

data "aws_availability_zones" "available" {}

resource "aws_subnet" "instance" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = data.aws_availability_zones.available.names[0]
  cidr_block        = "10.0.1.0/24"

  tags = {
    Name = "Subnet instance"
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/ansible-key.pem"
  file_permission = "0400"
}

resource "aws_key_pair" "key_pair" {
  key_name   = "ansible-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "aws_security_group" "allow_ssh" {
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "ansible_server" {
  ami                    = data.aws_ami.ubuntu.id
  subnet_id              = aws_subnet.instance.id
  instance_type          = "t2.micro"
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]
  key_name               = aws_key_pair.key_pair.key_name
  user_data              = "${path.module}/bootstrap.sh"

  tags = {
    Name = "Ansible Server"
  }
}

## creating public subnet
resource "aws_subnet" "nat_subnet" {
  availability_zone = data.aws_availability_zones.available.names[0]
  cidr_block = "10.0.2.0/24"
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "NAT Subnet"
  }
}

resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "Internet Gateway"
  }
}

resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }
}

resource "aws_route_table_association" "rt_associate" {
  subnet_id      = aws_subnet.nat_subnet.id
  route_table_id = aws_route_table.route_table.id
}

## creating NAT Gateway
resource "aws_eip" "ip_address" {
  vpc = true
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.ip_address.id
  subnet_id = aws_subnet.nat_subnet.id

  tags = {
    "Name" = "NAT Gateway"
  }
}

resource "aws_route_table" "instance" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }
}

resource "aws_route_table_association" "instance" {
  subnet_id      = aws_subnet.instance.id
  route_table_id = aws_route_table.instance.id
}

## creating a bastion instance
resource "aws_instance" "bastion_server" {
  ami                    = data.aws_ami.ubuntu.id
  subnet_id              = aws_subnet.nat_subnet.id
  instance_type          = "t2.micro"
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]
  key_name               = aws_key_pair.key_pair.key_name
  
  tags = {
    Name = "Bastion Server"
  }
}

resource "aws_eip" "bastion_server" {
  instance = aws_instance.bastion_server.id
  vpc      = true
}

output "Ansible_Server_IP" {
  value = aws_instance.ansible_server.private_ip
}

output "bastion_ip" {
  value = aws_eip.bastion_server.public_ip
}

resource "local_file" "ssh_file" {
  content         = templatefile("ssh_config.tftpl", {ansible_ip = "${aws_instance.ansible_server.private_ip}", key = "${path.module}/ansible-key.pem", bastion_ip = "${aws_eip.bastion_server.public_ip}"})
  filename        = "${path.module}/ssh_config.txt"
  file_permission = "0660"
}