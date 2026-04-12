# AWS Observability Platform

End-to-end observability platform using **AWS Managed Grafana**, **CloudWatch**, and **SNS** — fully deployed as Infrastructure as Code via CloudFormation and automated through GitHub Actions CI/CD pipelines.

---

## Architecture Overview

```
GitHub (source of truth)
       │
       ▼
GitHub Actions CI/CD
  ├── deploy-infra.yml        →  CloudFormation stacks
  └── deploy-dashboards.yml   →  Grafana API (dashboards + alerts)
       │
       ▼
AWS (ap-southeast-1)
  ├── Stack 1: SNS            →  Notification topic + email subscription
  ├── Stack 2: Grafana        →  Managed Grafana workspace + SSO + plugins
  └── Stack 3: CloudWatch     →  Log groups + metric filters + alarms + dashboard
```

---

## What Is Deployed

| Component | Description |
|---|---|
| AWS Managed Grafana | Grafana 10.4 workspace with SSO via IAM Identity Center |
| SSO Integration | IAM Identity Center group assigned Admin role |
| Grafana Plugins | piechart, clock, worldmap, JSON datasource — installed via CFN Custom Resource |
| CloudWatch Dashboard | 6 panels: EC2 CPU, Lambda metrics, app errors, log insights |
| CloudWatch Alarms | High error rate, Lambda errors, EC2 CPU > 80% |
| Grafana Alert Rules | 3 rules with A→B→C pattern, routed to SNS |
| SNS Notifications | Email subscription with contact point and notification policy |
| CI/CD Pipelines | Two GitHub Actions pipelines using OIDC (no stored AWS keys) |

---

## Repository Structure

```
aws-observability-platform/
├── .github/
│   └── workflows/
│       ├── deploy-infra.yml          # Deploys CFN stacks: SNS → Grafana → CloudWatch
│       └── deploy-dashboards.yml     # Deploys Grafana dashboards and alerts via HTTP API
├── cloudformation/
│   ├── 01-grafana.yml                # Grafana workspace + IAM roles + Lambda custom resource
│   ├── 02-cloudwatch-observability.yml  # Log groups + metric filters + alarms + CW dashboard
│   └── 03-sns-notifications.yml      # SNS topic + email subscription + topic policy
├── grafana/
│   ├── dashboards/
│   │   └── cloudwatch-dashboard.json # Grafana dashboard with 6 panels
│   └── alerts/
│       └── cloudwatch-alerts.json    # Alert rules + contact point + notification policy
├── scripts/
│   └── deploy_grafana_config.sh      # Deploys Grafana config via HTTP API
└── README.md
```

---

## Key Design Decisions

### 1. Three separate CloudFormation stacks
SNS is deployed first because both the Grafana and CloudWatch stacks need the SNS topic ARN as an input parameter. The GitHub Actions pipeline reads the ARN from the SNS stack outputs and passes it automatically — no hardcoding.

### 2. CFN Custom Resource for Grafana plugins
CloudFormation has no native resource type for installing Grafana plugins. A Lambda function is triggered by CloudFormation during stack creation, calls the Grafana HTTP API to install the plugins, and signals back with success or failure. If the Lambda fails, the entire stack rolls back automatically.

### 3. OIDC authentication — no stored AWS credentials
GitHub Actions authenticates to AWS using OpenID Connect (OIDC). GitHub generates a short-lived JWT token per pipeline run, AWS validates it against the OIDC provider, and returns temporary credentials. Zero long-lived keys stored anywhere in GitHub.

### 4. Temporary Grafana API key — 10-minute TTL
The dashboard pipeline creates a Grafana API key with a 600-second TTL, uses it to push dashboards and alerts, and the key auto-expires. The key is masked in all pipeline logs using `::add-mask::`.

### 5. Dashboards and alerts as code
All Grafana configuration (dashboards, alert rules, contact points, notification policies) is defined as JSON files in Git and deployed via the Grafana HTTP API. Nothing is manually configured in the UI. Git is the single source of truth.

---

## CI/CD Pipeline Flow

```
Push to main branch
       │
       ▼
deploy-infra.yml
  Step 1: Configure AWS via OIDC
  Step 2: Deploy SNS stack        → outputs SNS topic ARN
  Step 3: Deploy Grafana stack    → outputs Grafana URL + workspace ID
  Step 4: Deploy CloudWatch stack → uses SNS ARN from Step 2
       │
       ▼  (auto-triggered on completion)
deploy-dashboards.yml
  Step 1: Read Grafana URL from CFN outputs
  Step 2: Create temporary Grafana API key (TTL: 600s)
  Step 3: Run deploy_grafana_config.sh
           → Create Observability folder
           → Import CloudWatch dashboard
           → Deploy SNS contact point
           → Set notification policy
```

---

## Grafana Alert Rules

Each alert follows the **A → B → C pattern**:
- **A** — Query the CloudWatch metric
- **B** — Reduce the time series to a single value
- **C** — Evaluate the threshold condition

| Alert | Metric | Threshold | Severity |
|---|---|---|---|
| High Application Error Rate | Custom/dev — ApplicationErrors | > 10 errors in 5 min | Critical |
| Lambda Function Errors | AWS/Lambda — Errors | > 5 errors in 3 min | Warning |
| EC2 High CPU | AWS/EC2 — CPUUtilization | > 80% for 10 min | Warning |

All alerts route to SNS → email via the notification policy.

---

## GitHub Secrets Required

| Secret | Description |
|---|---|
| `AWS_ROLE_ARN` | IAM role ARN for GitHub Actions OIDC authentication |
| `AWS_ACCOUNT_ID` | 12-digit AWS account ID |
| `SSO_ORGANIZATION_ID` | IAM Identity Center Identity Store ID (d-xxxxxxxxxx) |
| `SSO_ADMIN_GROUP_ID` | SSO group ID for Grafana admin access |
| `NOTIFICATION_EMAIL` | Email address for SNS alert notifications |

---

## Deployment

### Automated (recommended)
Push any change to `main` → GitHub Actions deploys automatically.

### Manual via AWS CLI
```bash
# 1. Deploy SNS stack first
aws cloudformation deploy \
  --stack-name dev-observability-sns \
  --template-file cloudformation/03-sns-notifications.yml \
  --parameter-overrides Environment=dev NotificationEmail=your@email.com \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-1

# 2. Get SNS ARN
SNS_ARN=$(aws cloudformation describe-stacks \
  --stack-name dev-observability-sns \
  --query "Stacks[0].Outputs[?OutputKey=='SNSTopicArn'].OutputValue" \
  --output text --region ap-southeast-1)

# 3. Deploy Grafana stack
aws cloudformation deploy \
  --stack-name dev-grafana \
  --template-file cloudformation/01-grafana.yml \
  --parameter-overrides \
    WorkspaceName=dev-observability-workspace \
    SSOOrganizationId=<your-sso-id> \
    AdminGroupId=<your-group-id> \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-1

# 4. Deploy CloudWatch stack
aws cloudformation deploy \
  --stack-name dev-cloudwatch-observability \
  --template-file cloudformation/02-cloudwatch-observability.yml \
  --parameter-overrides Environment=dev SNSTopicArn=$SNS_ARN \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-1
```

---

## Cost

| Service | Cost | Notes |
|---|---|---|
| AWS Managed Grafana | ~$0.30/day | Only chargeable service — delete workspace after demo |
| CloudWatch | $0.00 | Within free tier (10 alarms, 5GB logs) |
| SNS | $0.00 | Within free tier (1M publishes) |
| Lambda | $0.00 | Within free tier (1M requests) |
| GitHub Actions | $0.00 | Free for public repos |

**To stop all billing:** Delete the `dev-grafana` CloudFormation stack immediately after the demo.

```bash
aws cloudformation delete-stack --stack-name dev-grafana --region ap-southeast-1
```

---

## Technologies Used

- **AWS Managed Grafana** — managed Grafana service with SSO
- **AWS CloudFormation** — infrastructure as code
- **AWS CloudWatch** — metrics, logs, alarms, dashboards
- **AWS SNS** — alert notifications
- **AWS Lambda** — CloudFormation custom resource handler
- **AWS IAM Identity Center** — SSO authentication
- **GitHub Actions** — CI/CD pipelines with OIDC
- **Python 3.12** — Lambda function runtime
- **Bash** — deployment scripting
