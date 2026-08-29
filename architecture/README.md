# Innovate Inc. — AWS Architecture Design

## 1. Executive Summary

Innovate Inc. is developing a web application with:

- Backend: Python / Flask REST API
- Frontend: React SPA
- Database: PostgreSQL
- Low initial traffic with expected rapid growth
- Sensitive user data
- Continuous integration and continuous delivery requirements

AWS is selected as the cloud provider.

The architecture is designed to be:

- secure
- scalable
- highly available
- cost-conscious
- observable
- automated
- ready for disaster recovery

The core design is based on:

- AWS Organizations / Control Tower
- Amazon EKS
- Karpenter
- Amazon ECR
- Amazon RDS for PostgreSQL
- Amazon S3
- Amazon CloudFront
- AWS WAF
- AWS Certificate Manager
- Route 53
- GitHub Actions
- Argo CD
- SonarQube
- Trivy
- Dependabot
- GuardDuty
- Security Hub
- Amazon Inspector
- CloudWatch
- SNS
- centralized log storage
- secondary DR region

---

# 2. Cloud Environment Structure

## 2.1 Recommended AWS Account Structure

The recommended target structure is:

```text
AWS Organization
├── Management
├── Security / Audit
├── Log Archive
├── DEV
├── STAGING
├── PRE-PROD
└── PROD
```

The STAGING account contains separate QA and UAT environments:

```text
STAGING EKS
├── QA namespace
└── UAT namespace
```

For a small startup, the full multi-account structure can be introduced gradually. However, this is the recommended production-ready target state.

## 2.2 Management Account

The Management account is used only for organization-level governance.

Responsibilities include:

- AWS Organizations
- Organizational Units
- Service Control Policies
- AWS Control Tower
- centralized billing
- account provisioning
- delegated administrator configuration

Application workloads should not run in this account.

## 2.3 Security / Audit Account

The Security / Audit account is used as the centralized security administration plane.

Responsibilities include:

- Security Hub delegated administration
- GuardDuty delegated administration
- Amazon Inspector delegated administration
- centralized security findings
- security investigations
- cross-account audit access

Security services remain enabled in workload accounts, but findings are aggregated centrally.

This provides an independent security boundary even if one of the workload accounts is compromised.

## 2.4 Log Archive Account

The Log Archive account is used as a centralized destination for security and infrastructure logs.

Typical logs include:

1. **AWS WAF logs** — record HTTP(S) requests inspected by AWS WAF and the decision taken for each request. They typically include the source IP address, URI, HTTP method, selected headers, matched rule, action (`ALLOW`, `BLOCK`, `COUNT`), request timestamp, and Web ACL information. These logs are useful for investigating attacks, rate-limiting events, blocked traffic, and false positives.

2. **CloudFront logs** — record requests processed by the CloudFront distribution. They include information such as client IP address, requested URL/path, HTTP status code, bytes transferred, user agent, referrer, cache hit/miss result, edge location, and request timing information. They are useful for traffic analysis, troubleshooting delivery errors, measuring cache efficiency, and understanding user access patterns.

3. **ALB access logs** — record requests received by the Application Load Balancer. They include client IP, target IP, request path, HTTP method, load balancer response code, target response code, request processing time, target processing time, TLS information, and user agent. They are useful for investigating backend latency, HTTP 4xx/5xx errors, unhealthy targets, and target group issues.

4. **VPC Flow Logs** — capture network metadata at the VPC, subnet, or ENI level. They include source and destination IP addresses, source and destination ports, protocol, packet and byte counts, network interface ID, time interval, and whether traffic was `ACCEPT`ed or `REJECT`ed. Packet payloads are not captured. Flow Logs are useful for network troubleshooting, Security Group/NACL analysis, and detecting suspicious network communication.

5. **Route 53 query logs** — record DNS queries handled by Route 53. They include the queried domain name, DNS record type (`A`, `AAAA`, `CNAME`, etc.), timestamp, source resolver/client information, and query response details. They are useful for troubleshooting DNS issues and investigating suspicious or unexpected DNS activity.

6. **Other security and audit logs** — include AWS CloudTrail events, AWS Config configuration history, GuardDuty and Security Hub findings, EKS control-plane logs, RDS audit/error logs, CloudWatch application logs, and S3 access logs where required.

Recommended controls for the centralized log archive:

- S3 versioning
- KMS encryption
- restrictive bucket policies
- S3 Object Lock where required
- lifecycle policies

Production administrators should not have permissions to delete archived audit logs.

## 2.5 Environment Accounts

### DEV

Used for active development.

Cost optimization can be aggressive:

- smaller instances
- Spot capacity
- Graviton
- one NAT Gateway
- aggressive Karpenter consolidation

### STAGING

Used for QA and UAT.

The environments are separated using:

- Kubernetes namespaces
- RBAC
- ResourceQuotas
- environment-specific configuration

### PRE-PROD

PRE-PROD should be architecturally as close to PROD as possible.

It should use the same:

- Terraform modules
- EKS architecture
- Kubernetes manifests
- Argo CD deployment process
- PostgreSQL major version
- networking model
- security controls

Capacity can be smaller than production.

### PROD

The PROD account contains only production workloads and production data.

## 2.6 Why Separate AWS Accounts?

Separate AWS accounts provide:

- strong blast-radius isolation
- separate IAM security boundaries
- cleaner billing and cost allocation
- independent AWS service quotas
- easier production access control
- reduced risk of DEV/STAGING changes affecting PROD
- the ability to apply SCPs by Organizational Unit

In short:

```text
Accounts
= security, billing and operational isolation
```

---

# 3. High-Level Architecture Diagram

The high-level AWS architecture is maintained as a separate Mermaid diagram:

[hld.mmd](./hld.mmd)

The diagram illustrates:

- AWS account and organizational boundaries
- CloudFront, WAF, S3 and OAC for the React SPA
- the production VPC and subnet tiers
- Amazon EKS, Managed Node Groups and Karpenter
- Flask application workloads
- RDS PostgreSQL Multi-AZ and the analytics Read Replica
- application and infrastructure observability
- centralized security and logging
- CI/CD with GitHub Actions and Argo CD
- the secondary disaster recovery region

Keeping the HLD in a separate file makes the architecture easier to review and update without embedding a large Mermaid definition inside this README.

---

# 4. Network Design

## 4.1 VPC Architecture

Each environment has its own VPC.

Production uses three Availability Zones.

Each AZ contains three subnet tiers:

```text
VPC
├── AZ-A
│   ├── Public Subnet
│   ├── Private Application Subnet
│   └── Isolated Database Subnet
│
├── AZ-B
│   ├── Public Subnet
│   ├── Private Application Subnet
│   └── Isolated Database Subnet
│
└── AZ-C
    ├── Public Subnet
    ├── Private Application Subnet
    └── Isolated Database Subnet
```

## 4.2 Public Subnets

Public subnets are used for:

- Application Load Balancer
- NAT Gateways

They have a default route to the Internet Gateway:

```text
0.0.0.0/0 -> Internet Gateway
```

## 4.3 Private Application Subnets

Private application subnets are used for:

- EKS Managed Nodes
- Karpenter-created worker nodes

Worker nodes do not receive public IP addresses.

Outbound internet traffic follows:

```text
Private Subnet
   |
NAT Gateway
   |
Internet Gateway
```

For PROD, one NAT Gateway per AZ is recommended to avoid a single-AZ dependency.

For DEV and STAGING, a single NAT Gateway is acceptable to reduce cost.

## 4.4 Isolated Database Subnets

RDS PostgreSQL is deployed into isolated database subnets.

These subnets do not have a direct route to the Internet Gateway.

## 4.5 VPC Endpoints

Where useful, VPC endpoints should be used for:

- S3
- ECR API
- ECR Docker
- STS
- CloudWatch Logs
- Secrets Manager

VPC endpoints are used so that private EKS worker nodes and applications can access supported AWS services without sending that traffic through a NAT Gateway or the public internet.

Benefits include:

- **Improved security** — traffic to supported AWS services stays on the AWS network and does not require public IP connectivity.
- **Reduced NAT Gateway cost** — high-volume traffic such as ECR image pulls and S3 access can avoid NAT Gateway data processing charges.
- **Reduced dependency on internet egress** — private workloads can access AWS APIs even when direct internet access is intentionally restricted.
- **Simpler network controls** — endpoint policies and Security Groups can restrict which services and resources private workloads are allowed to access.
- **Better architecture for private EKS clusters** — worker nodes can pull images from ECR, write logs to CloudWatch, retrieve secrets, and access S3 while remaining in private subnets.

Example traffic flow:

```text
EKS Worker Node
      |
      +--> ECR VPC Endpoint ------> Amazon ECR
      |
      +--> S3 Gateway Endpoint ---> Amazon S3
      |
      +--> Secrets Endpoint ------> Secrets Manager
      |
      +--> Logs Endpoint ---------> CloudWatch Logs
```

Without these endpoints, the same private workloads would normally reach those public AWS service endpoints through the NAT Gateway.

## 4.6 Network Security

Traffic flow:

```text
Internet
   |
CloudFront + WAF
   |
Application Load Balancer
   |
EKS private worker nodes
   |
Kubernetes NetworkPolicies
   |
RDS PostgreSQL in isolated subnets
```

The security model uses several independent layers.

### AWS WAF at CloudFront

AWS WAF filters HTTP(S) traffic at the edge before requests reach the application.

Recommended controls include:

- AWS Managed Rules
- common exploit protection
- SQL injection and XSS protection
- IP reputation rules
- rate limiting
- blocking known malicious request patterns

This reduces the amount of unwanted traffic that reaches the application infrastructure.

### Restrictive Security Groups

Security Groups are configured using a least-privilege approach.

Only the required traffic between application layers is allowed.

Example:

```text
CloudFront / Internet
        |
      HTTPS
        v
      ALB SG
        |
application traffic
        v
 EKS application tier
        |
 PostgreSQL 5432
        v
      RDS SG
```

The RDS Security Group allows PostgreSQL traffic only from the application tier.

### Private EKS Worker Nodes

EKS worker nodes run in private application subnets and do not receive public IP addresses.

They are not directly reachable from the internet.

Outbound access is provided through:

- NAT Gateways when internet access is required
- VPC endpoints for supported AWS services such as ECR, S3, STS, Secrets Manager and CloudWatch

This reduces the external attack surface of the Kubernetes nodes.

### Private Database

RDS PostgreSQL runs in isolated database subnets.

The database:

- has no public IP address
- has no direct route to the Internet Gateway
- accepts PostgreSQL connections only from approved application sources
- is not exposed directly to users or the public internet

### Kubernetes NetworkPolicies

Kubernetes NetworkPolicies restrict east-west traffic between Pods and namespaces.

Pods do not automatically need unrestricted access to every other workload in the cluster.

NetworkPolicies can be used to enforce rules such as:

```text
Frontend/API namespace
        |
        v
Backend service

Backend
        |
        v
Database-related endpoints

Other Pods
   X
unauthorized traffic blocked
```

This provides an additional security layer inside the EKS cluster.

### VPC Flow Logs

VPC Flow Logs capture network metadata at the VPC, subnet or ENI level.

They record information such as:

- source IP
- destination IP
- source port
- destination port
- protocol
- packet and byte counts
- `ACCEPT` or `REJECT`
- network interface
- time interval

Packet payloads are not captured.

Flow Logs are useful for:

- network troubleshooting
- Security Group and NACL analysis
- identifying rejected connections
- detecting unusual network communication
- security investigations

### TLS Encryption

Sensitive traffic is encrypted in transit.

Examples:

```text
User -> CloudFront
HTTPS

CloudFront -> ALB
HTTPS

Application -> sensitive backend services
TLS where supported

Application -> PostgreSQL
TLS
```

AWS Certificate Manager is used to manage public TLS certificates.

### No Unnecessary Inbound Rules

Inbound access follows least privilege.

Internal services should not expose ports such as:

```text
22    SSH
5432  PostgreSQL
6443  Kubernetes API
```

to `0.0.0.0/0` unless there is a specific and documented requirement.

Only the minimum required ports and trusted source Security Groups or CIDRs should be permitted.

### AWS Secrets Manager

Credentials and application secrets are stored in AWS Secrets Manager.

Examples include:

- database passwords
- API keys
- third-party credentials
- application tokens

Secrets must not be stored in:

- Git repositories
- Docker images
- plaintext Kubernetes manifests
- application configuration files committed to source control

EKS workloads obtain access to required secrets through a controlled IAM identity such as IRSA or EKS Pod Identity.

In summary:

```text
Edge protection
      |
CloudFront + WAF
      |
Network isolation
      |
Security Groups + private subnets
      |
Kubernetes isolation
      |
NetworkPolicies
      |
Data protection
      |
TLS + Secrets Manager
```

In short:

```text
Network design
= public edge, private compute, isolated database, least-privilege access
```

---

# 5. Compute Platform

## 5.1 Kubernetes Service

Amazon EKS is used to run the Python / Flask backend.

The React frontend is not deployed to Kubernetes because the production build produces static assets.

Frontend build:

```text
npm ci
   |
npm run build
   |
dist/
   |
Private S3
   |
CloudFront
```

Typical build output:

```text
index.html
*.js
*.css
images/
assets/
```

Backend request flow:

```text
CloudFront
   |
/api/*
   |
ALB
   |
EKS
   |
Flask Pods
   |
RDS PostgreSQL
```

The backend is deployed with standard Kubernetes resources such as:

- Deployment
- Service
- Ingress
- ConfigMap
- HPA
- PodDisruptionBudget

Secrets are sourced from AWS Secrets Manager rather than stored in Git.

## 5.2 Node Groups

A small EKS Managed Node Group provides stable On-Demand capacity.

It runs critical system workloads such as:

- Karpenter controller
- CoreDNS
- Argo CD
- monitoring components
- other operational services

Example:

```text
Managed Node Group
2-3 On-Demand nodes
```

Application capacity is provisioned dynamically by Karpenter.

Karpenter can provide:

- x86_64
- ARM64 / Graviton
- Spot
- On-Demand

For stateless Flask workloads, Graviton and Spot should be preferred where compatible because they provide lower compute cost.

Critical workloads remain on On-Demand capacity.

## 5.3 Pod and Node Scaling

Pod scaling and node scaling are separate concerns:

```text
HPA
= scales Pods

Karpenter
= scales Nodes
```

Scale-out flow:

```text
Traffic increases
      |
HPA creates more Flask Pods
      |
Pods cannot be scheduled
      |
Karpenter provisions EC2 capacity
      |
Pods are scheduled
```

Scale-in flow:

```text
Traffic decreases
      |
HPA reduces replicas
      |
capacity becomes unused
      |
Karpenter consolidates nodes
      |
unused EC2 instances are terminated
```

## 5.4 Resource Allocation

All application Pods should define explicit CPU and memory requests and limits.

Example:

```yaml
resources:
  requests:
    cpu: "250m"
    memory: "256Mi"
  limits:
    cpu: "1"
    memory: "512Mi"
```

Requests are important because Kubernetes uses them for Pod scheduling and HPA/Karpenter capacity planning. Limits protect the cluster from a single workload consuming an uncontrolled amount of CPU or memory.

Production workloads should also define:

- readiness probes
- liveness probes
- PodDisruptionBudgets
- topologySpreadConstraints

Taints, tolerations, node selectors and affinity are used where workloads require dedicated capacity.

Production Flask Pods should be spread across Availability Zones.

---

# 6. Containerization, Registry and Deployment

## 6.1 Backend Containerization

The Flask application is packaged as a Docker image.

Recommended practices:

- multi-stage builds
- minimal runtime image
- non-root user
- no secrets in images
- immutable image tags
- Git commit SHA as the deployment tag

Example:

```text
innovate-api:8ac37e2
```

The `latest` tag is not used for production deployments.

## 6.2 Amazon ECR

Images are pushed to Amazon ECR.

Example:

```text
123456789012.dkr.ecr.eu-west-1.amazonaws.com/innovate-api:8ac37e2
```

ECR cross-region replication copies production images to the DR region.

## 6.3 Backend CI/CD

GitHub Actions is used for CI.

Argo CD is used for Kubernetes CD.

GitHub Actions authenticates to AWS through OIDC rather than static AWS access keys.

Pipeline:

```text
Checkout
   |
Unit Tests
   |
Lint
   |
SonarQube
   |
Docker Build
   |
Trivy
   |
ECR Push
   |
GitOps Update
   |
Argo CD
   |
EKS
```

## 6.4 Security Gates

SonarQube checks:

- bugs
- code smells
- duplicated code
- maintainability
- security hotspots
- test coverage

Trivy scans the built image.

Production policy:

```text
CRITICAL vulnerability
   |
pipeline fails
   |
production deployment blocked
```

HIGH, MEDIUM and LOW findings are reported but do not automatically block PROD.

Dependabot monitors:

- Python dependencies
- npm dependencies
- Docker images
- Terraform
- GitHub Actions

## 6.5 Frontend CI/CD

Frontend pipeline:

```text
Git Push
   |
npm ci
   |
npm run build
   |
Tests / SonarQube
   |
dist/
   |
S3 Sync
   |
CloudFront Invalidation
```

## 6.6 Environment Promotion

```text
DEV
 |
STAGING
 |-- QA
 |-- UAT
 |
PRE-PROD
 |
Manual Approval
 |
PROD
```

The same immutable image is promoted between environments instead of being rebuilt.

---

# 7. Database Design

## 7.1 Recommended PostgreSQL Service

The recommended service is:

```text
Amazon RDS for PostgreSQL
Multi-AZ
```

RDS is preferred over running PostgreSQL inside EKS because it provides:

- managed PostgreSQL
- automated backups
- automated failover
- point-in-time recovery
- automated maintenance
- CloudWatch integration
- KMS encryption
- lower operational overhead
- no need to manage StatefulSets, storage replication or database failover manually

Aurora PostgreSQL can be evaluated later if workload scale, read performance or multi-region requirements justify the additional cost.

## 7.2 High Availability

Production uses RDS Multi-AZ.

```text
AZ-A
Primary PostgreSQL
      |
      | synchronous replication
      v
AZ-B
Standby PostgreSQL
```

If the primary instance fails:

```text
Primary failure
   |
RDS detects failure
   |
automatic failover
   |
standby is promoted
   |
application continues through RDS endpoint
```

The Multi-AZ standby is used for high availability, not analytics.

## 7.3 Analytics Read Replica

A separate PostgreSQL Read Replica is created for analysts and reporting workloads.

```text
Primary RDS
   |
   | asynchronous replication
   v
Analytics Read Replica
   |
BI / Analysts
```

This prevents expensive analytical queries from affecting the transactional production database.

The analytics account should use read-only credentials.

The replica may have a small replication lag, which is acceptable for reporting workloads.

In short:

```text
Multi-AZ Standby
= high availability

Read Replica
= analytics / read scaling
```

## 7.4 Backups and Point-in-Time Recovery

Production database protection includes:

- automated RDS backups
- point-in-time recovery
- 14-35 day retention
- AWS Backup policies
- manual snapshots before major database changes
- KMS encryption

Multi-AZ protects against infrastructure failure, but it does not protect against logical errors.

For example:

```text
DELETE FROM users;
```

would also be replicated to the standby.

PITR and backups protect against:

- accidental data deletion
- bad deployments
- application bugs
- database corruption caused by human error

## 7.5 Disaster Recovery

Primary region:

```text
eu-west-1
```

DR region:

```text
us-east-2 (Ohio)
```

A DR RDS instance is maintained in the DR region.

Daily flow:

```text
Primary PROD RDS
      |
Create Snapshot
      |
Cross-Region Snapshot Copy
      |
Restore / Refresh DR RDS
```

This provides an approximate RPO of up to 24 hours.

If a lower RPO becomes necessary, cross-region replication or Aurora Global Database can replace the snapshot-based design.

## 7.6 DR Application Recovery

ECR images are replicated automatically:

```text
eu-west-1 ECR
      |
Cross-Region Replication
      |
us-east-2 ECR
```

To reduce cost, DR EKS does not run permanently.

During a disaster:

```text
GitHub Actions workflow_dispatch
      |
Terraform
      |
Create DR EKS
      |
Bootstrap Argo CD
      |
Argo CD sync
      |
Pull replicated ECR images
      |
Connect to DR RDS
      |
Smoke tests
      |
DNS failover
```

This provides a cost-effective DR strategy while preserving an automated recovery path.

---

# 8. Monitoring and Alerting

CloudWatch is used as the primary AWS infrastructure monitoring and alerting layer.

For Kubernetes and application-level observability, the platform can additionally adopt the `kube-prometheus-stack` as the environment grows.

A future monitoring architecture can look like:

```text
Flask / Application Pods
        |
      /metrics
        |
   Prometheus
        |
      Grafana
        |
Application / Business Dashboards
        |
        +---- CloudWatch Data Source
                 |
                 v
          AWS Infrastructure Metrics
```

## 8.1 Application and Business Metrics

Applications should expose custom Prometheus-format metrics through an HTTP endpoint such as:

```text
/metrics
```

Examples of application metrics:

- request count
- request latency
- error count / error rate
- active requests
- background job duration
- queue depth
- external API latency

Examples of business metrics:

- registrations
- successful transactions
- failed transactions
- active users
- orders processed
- domain-specific business events

These metrics allow monitoring to go beyond CPU and memory and show whether the application is actually functioning correctly from a business perspective.

With Prometheus Operator, application metrics can be discovered through Kubernetes objects such as `ServiceMonitor` or `PodMonitor`.

Example flow:

```text
Flask Pod /metrics
      |
ServiceMonitor
      |
Prometheus
      |
Grafana
```

## 8.2 Future kube-prometheus-stack

As the platform grows, `kube-prometheus-stack` can be deployed to provide:

- Prometheus
- Prometheus Operator
- Alertmanager
- Grafana
- kube-state-metrics
- node-exporter
- standard Kubernetes dashboards and alerting rules

Grafana dashboards should cover:

- Flask/API performance
- custom application metrics
- business KPIs
- Kubernetes cluster health
- Pod and Deployment health
- node utilization
- HPA behavior
- Karpenter capacity and scaling

Grafana can also use CloudWatch as a data source, allowing AWS service metrics to be displayed alongside Prometheus metrics.

This provides a single observability view for:

```text
Application metrics
+
Business metrics
+
Kubernetes metrics
+
AWS / CloudWatch metrics
```

## 8.3 ALB / API Alarms

Recommended CloudWatch alarms:

- unhealthy target count
- target 5xx error rate
- response latency
- abnormal request rate
- failed health checks

## 8.4 EKS / Kubernetes Monitoring

Monitor:

- node CPU
- node memory
- disk pressure
- NodeNotReady
- unschedulable Pods
- Pod restart spikes
- CrashLoopBackOff
- HPA saturation
- Karpenter provisioning failures
- node launch failures
- Spot interruptions

Prometheus-based alerts can additionally be used for Kubernetes-specific conditions that are not naturally represented by CloudWatch metrics.

## 8.5 RDS Monitoring

Recommended alarms:

- CPUUtilization
- FreeableMemory
- FreeStorageSpace
- DatabaseConnections
- ReadLatency
- WriteLatency
- replication lag
- abnormal PostgreSQL WAL / transaction log growth

WAL growth is treated as an early warning because it may indicate:

- long-running transactions
- replication issues
- replication slot problems
- vacuum problems
- storage pressure

## 8.6 Other Infrastructure Alarms

Monitor:

- CloudFront 5xx rates
- unusual CloudFront 4xx rates
- WAF blocked request spikes
- NAT Gateway ErrorPortAllocation
- NAT Gateway PacketsDropCount
- failed backups
- failed snapshot copies
- ECR replication failures
- failed DR workflows

---

# 9. Alert Delivery and Deployment Notifications

CloudWatch Alarms publish to Amazon SNS.

```text
CloudWatch Alarms
      |
Amazon SNS
   /   |   \
  /    |    \
Slack Teams Email
             |
      PagerDuty / Opsgenie
      optional
```

Recommended severity model:

### CRITICAL

Examples:

- API unavailable
- RDS unavailable
- ALB unhealthy
- free database storage critically low
- backup failed
- DR workflow failed

Delivery:

- Slack / Teams
- Email
- optional PagerDuty / Opsgenie

### WARNING

Examples:

- high CPU
- high latency
- memory pressure
- abnormal WAL growth
- elevated error rate

Delivery:

- operational Slack / Teams channel

GitHub Actions deployment workflows also send notifications for:

```text
PROD deployment started
PROD deployment succeeded
PROD deployment failed
Rollback triggered
DR deployment started
DR deployment succeeded
DR deployment failed
Trivy blocked deployment
SonarQube quality gate failed
```

---

# 10. Runtime Security

GuardDuty Runtime Monitoring is enabled for EKS.

The GuardDuty agent runs on worker nodes and monitors runtime activity.

Conceptually:

```text
EKS Workers
   |
GuardDuty Runtime Agent
   |
GuardDuty
   |
Security Hub
   |
Security / Audit Account
```

Security responsibilities:

```text
Amazon Inspector
= CVEs and vulnerabilities

GuardDuty
= suspicious runtime activity

Security Hub
= centralized security findings
```

---

# 11. Logging and S3 Lifecycle Management

The Log Archive account stores centralized logs in S3.

Lifecycle example:

```text
0-30 days
S3 Standard
   |
30-90 days
S3 Standard-IA
   |
90-365 days
Glacier Flexible Retrieval
   |
365+ days
Glacier Deep Archive
   |
Retention expires
Delete
```

Exact retention depends on business and legal requirements.

Additional lifecycle controls:

- delete expired noncurrent versions
- abort incomplete multipart uploads
- delete data after the retention period

For the frontend bucket:

```text
Current assets
= retained

Old noncurrent versions
= automatically removed
```

---

# 12. Cost Optimization

Recommended cost controls:

- React on S3 + CloudFront instead of frontend Pods
- Spot for stateless workloads
- Graviton where compatible
- Karpenter consolidation
- right-sized Pod requests
- right-sized RDS
- one NAT Gateway in lower environments
- smaller PRE-PROD
- non-production scale-down
- S3 lifecycle policies
- Glacier / Deep Archive for old logs
- DR EKS created only during disaster activation
- ECR replication instead of rebuilding images during DR
- AWS Budgets
- Cost Anomaly Detection

---

# 13. Key Design Decisions

| Area | Decision |
|---|---|
| Cloud | AWS |
| Account Model | Multi-account AWS Organization |
| Governance | AWS Organizations / Control Tower |
| Frontend | Private S3 + CloudFront |
| S3 Access | OAC |
| Edge Security | AWS WAF |
| TLS | ACM |
| Backend | Amazon EKS |
| Node Scaling | Karpenter |
| Stable Nodes | EKS Managed Node Group / On-Demand |
| Cost Capacity | Spot + Graviton |
| Registry | Amazon ECR |
| ECR DR | Cross-Region replication |
| CI | GitHub Actions |
| CD | Argo CD |
| Code Quality | SonarQube |
| Dependencies | Dependabot |
| Image Scan | Trivy |
| PROD Security Gate | CRITICAL vulnerabilities only |
| Database | RDS PostgreSQL Multi-AZ |
| Analytics | PostgreSQL Read Replica |
| DB Backups | Automated backups + PITR + AWS Backup |
| DR Database | Daily snapshot copy + restore to us-east-2 |
| DR Compute | EKS created on demand |
| Runtime Security | GuardDuty Runtime Monitoring |
| Vulnerability Scanning | Amazon Inspector |
| Security Aggregation | Security Hub |
| Monitoring | CloudWatch |
| Alert Routing | SNS |
| Notifications | Slack / Teams / Email |
| Logs | Central Log Archive account |
| Log Cost | S3 Lifecycle + Glacier |
| Secrets | AWS Secrets Manager |

---

# 14. Summary

The proposed design addresses the four core assignment areas directly:

```text
Cloud Environment Structure
-> strong account-level isolation, governance and billing separation

Network Design
-> public edge, private compute and isolated database tiers

Compute Platform
-> EKS, HPA, Karpenter, ECR and GitOps-based deployments

Database
-> RDS PostgreSQL Multi-AZ, analytics replica, backups and cross-region DR
```

The platform can start with a low-cost footprint and scale toward a much larger workload without requiring a major redesign.
