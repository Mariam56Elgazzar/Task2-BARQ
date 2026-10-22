output "app_public_ip" {
  value = aws_instance.app.public_ip
}

output "app_private_ip" {
  value = aws_instance.app.private_ip
}

output "db_public_ip" {
  description = "Used only for SSH/Ansible. PostgreSQL is not reachable here."
  value       = aws_instance.db.public_ip
}

output "db_private_ip" {
  value = aws_instance.db.private_ip
}

output "ssh_user" {
  value = var.ssh_user
}

output "ssh_private_key_path" {
  value = pathexpand(var.ssh_private_key_path)
}

output "admin_cidr" {
  description = "IP range allowed to SSH."
  value       = local.admin_cidr
}

output "ansible_inventory" {
  description = "Rendered Ansible inventory (written to ansible/inventory/hosts.yml by scripts/deploy.sh)."
  value = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    app_public_ip        = aws_instance.app.public_ip
    app_private_ip       = aws_instance.app.private_ip
    db_public_ip         = aws_instance.db.public_ip
    db_private_ip        = aws_instance.db.private_ip
    pg_data_volume_id    = aws_ebs_volume.db_data.id
    ssh_user             = var.ssh_user
    ssh_private_key_path = pathexpand(var.ssh_private_key_path)
  })
}
output "pg_data_volume_id" {
  description = "Dedicated EBS volume ID attached to the database instance."
  value       = aws_ebs_volume.db_data.id
}
