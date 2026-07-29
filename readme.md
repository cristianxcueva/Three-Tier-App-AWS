# Three-Tier AWS Web App

A highly available, fault tolerant web application deployed on AWS across multiple availability zones. Built as a cloud engineering portfolio project to demonstrate real infrastructure-as-code skills on AWS.

---

## Architecture

![Architecture Diagram](docs/three-tier-ha-arch.png)

Three tiers, two availability zones, no single points of failure.

**Frontend tier:** Static HTML/CSS/JS served from a private S3 bucket through CloudFront with Origin Access Control. CloudFront handles HTTPS termination and caches content at edge locations globally.

**Application tier:** Two EC2 t3.micro instances managed by an Auto Scaling Group, one in us-east-1a and one in us-east-1b. An Application Load Balancer distributes traffic across both instances and health-checks port 8080 every 30 seconds. If an instance fails, the ALB stops routing to it and the ASG replaces it automatically. Port 8080 on EC2 is locked to the ALB's security group only, not the open internet.

**Database tier:** RDS PostgreSQL 15.7 in private subnets with Multi-AZ enabled. AWS maintains a synchronous standby replica in us-east-1b. Failover to the standby takes roughly two minutes with no data loss. EC2 instances fetch database credentials from Secrets Manager at runtime using an IAM instance profile, no hardcoded credentials anywhere.

---

## Tech Stack

| Layer | Service |
|---|---|
| Frontend hosting | S3 + CloudFront (OAC) |
| Load balancing | Application Load Balancer |
| Compute | EC2 t3.micro (Auto Scaling Group, min 1, desired 2, max 3) |
| Database | RDS PostgreSQL 15.7 (Multi-AZ) |
| Secrets | AWS Secrets Manager |
| IaC | Terraform |
| Monitoring | CloudWatch (ASG CPU alarm, threshold 80%) |

---

## Project Structure

```
Three-Tier-App-AWS/
├── terraform/
│   └── main.tf          # All infrastructure
├── frontend/
│   └── index.html       # Frontend template (backend_url injected at apply time)
└── docs/
    └── three-tier-ha-arch.png
```

---

## Known Limitation

The frontend calls the ALB over plain HTTP. The page itself loads over HTTPS through CloudFront, so browsers block the cross-protocol fetch request (mixed content). The fix is an ACM certificate attached to the ALB with an HTTPS listener. Skipped here to avoid the cost of a registered domain and cert validation for a portfolio project.

---

## What I Learned

**Networking and security group chaining.** Locking port 8080 to the ALB's security group ID rather than `0.0.0.0/0` means EC2 instances are unreachable directly from the internet even though they sit in public subnets. The ALB is the only thing that can reach them on that port.

**Launch templates vs direct EC2 resources.** ASGs require a launch template, not an `aws_instance` resource. The `user_data` script that installs Node.js runs automatically on every new instance the ASG launches, no manual setup needed.

**Public IP assignment in launch templates.** Without a `network_interfaces` block explicitly setting `associate_public_ip_address = true`, instances in public subnets launch with no public IP. The `user_data` script then silently fails trying to run `yum install` because there is no internet route, and the Node.js server never starts. The ALB reports unhealthy targets with no obvious explanation until you check the instance console output.

**Instance refresh for launch template changes.** Updating a launch template doesn't automatically cycle existing ASG instances. You have to trigger an instance refresh explicitly, or terminate instances manually so the ASG replaces them with the updated config.

**Multi-AZ RDS is an in-place modification.** Adding `multi_az = true` to a running RDS instance triggers a live modification, not a destroy-and-recreate. AWS provisions the standby replica in the background. The primary stays available throughout.

---

## Cleanup

```bash
terraform destroy
```

All infrastructure tears down cleanly. `skip_final_snapshot = true` on the RDS instance means no manual snapshot cleanup needed.

---

## Build History

This project started as a single-AZ architecture with a single EC2 instance and no load balancer. The upgrade to ALB, ASG, and Multi-AZ RDS is documented commit by commit in the git history. 