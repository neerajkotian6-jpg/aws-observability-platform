# AWS Observability Platform

This project sets up an observability platform on AWS using Managed Grafana, CloudWatch and SNS. Everything is written as Infrastructure as Code using CloudFormation templates and deployed automatically through GitHub Actions pipelines.

---

## What this project does

The idea was to build a complete monitoring setup where:
- Grafana is provisioned automatically with SSO login (no manual user management)
- CloudWatch collects metrics and logs from AWS services
- Alerts fire to email via SNS when something goes wrong
- All of this deploys automatically when code is pushed to GitHub — no manual steps in the AWS console

---

## Folder structure

```
aws-observability-platform/
├── .github/
│   └── workflows/
│       ├── deploy-infra.yml          # pipeline that deploys the 3 CFN stacks
│       └── deploy-dashboards.yml     # pipeline that pushes dashboards and alerts to Grafana
├── cloudformation/
│   ├── 01-grafana.yml                # Grafana workspace, IAM role, Lambda for plugins
│   ├── 02-cloudwatch-observability.yml  # log groups, alarms, metric filter, CW dashboard
│   └── 03-sns-notifications.yml      # SNS topic and email subscription
├── grafana/
│   ├── dashboards/
│   │   └── cloudwatch-dashboard.json
│   └── alerts/
│       └── cloudwatch-alerts.json
├── scripts/
│   └── deploy_grafana_config.sh
└── README.md
```

---

## How the deployment works

There are two GitHub Actions pipelines:

**Pipeline 1 — deploy-infra.yml**

Runs when anything in `cloudformation/` changes. Deploys the three stacks in a specific order because the SNS topic has to exist before the other two stacks can reference its ARN:

```
SNS stack → Grafana stack → CloudWatch stack
```

Each stack's outputs are read and passed as inputs to the next stack automatically.

**Pipeline 2 — deploy-dashboards.yml**

Runs after Pipeline 1 finishes, or when Grafana JSON files change. It:
1. Gets the Grafana workspace URL from the CFN stack outputs
2. Creates a temporary API key (expires in 10 minutes)
3. Calls the Grafana HTTP API to push dashboards, alert rules and the SNS contact point
4. The API key expires automatically after the pipeline finishes

Both pipelines authenticate to AWS using OIDC — no access keys are stored in GitHub at all.

---

## CloudFormation stacks

**03-sns-notifications.yml**

Creates the SNS topic and email subscription. Also sets up the topic policy so CloudWatch and Grafana are allowed to publish to it. Deployed first because the other stacks need the topic ARN.

**01-grafana.yml**

Creates the Grafana workspace with SSO authentication and CloudWatch as a data source. Also includes two Lambda functions as CloudFormation Custom Resources:
- One installs Grafana plugins (piechart, clock, worldmap, JSON datasource)
- One assigns the SSO group as Admin in the workspace

I had to use Custom Resources here because CloudFormation does not have native support for installing Grafana plugins or assigning SSO roles directly.

**02-cloudwatch-observability.yml**

Sets up the CloudWatch side of things:
- Two log groups for application and system logs
- A metric filter that turns ERROR log lines into a CloudWatch metric
- Three alarms (high error rate, Lambda errors, EC2 CPU)
- A CloudWatch dashboard with panels for all key metrics

---

## Grafana alerts

Each alert rule follows the same three-step structure:

- **Step A** — queries the CloudWatch metric
- **Step B** — reduces the data to a single number
- **Step C** — checks if that number crosses the threshold

| Alert | Condition | Severity |
|---|---|---|
| High Application Error Rate | more than 10 errors in 5 minutes | critical |
| Lambda Function Errors | more than 5 errors in 3 minutes | warning |
| EC2 High CPU | above 80% for 10 minutes | warning |

When an alert fires it goes to the SNS contact point which sends an email.

---

## GitHub Secrets needed

| Secret | What it is |
|---|---|
| `AWS_ROLE_ARN` | the IAM role GitHub Actions assumes via OIDC |
| `AWS_ACCOUNT_ID` | your AWS account ID |
| `SSO_ORGANIZATION_ID` | Identity Store ID from IAM Identity Center (starts with d-) |
| `SSO_ADMIN_GROUP_ID` | the group ID of the Grafana admin group in SSO |
| `NOTIFICATION_EMAIL` | email address for alert notifications |

---

## Region note

AWS Managed Grafana CloudFormation support is not available in all regions. This project uses **ap-southeast-1 (Singapore)** as it is the closest supported region to India.

---

## Cost

The only service that costs money is AWS Managed Grafana (~$0.30 per day). Everything else — CloudWatch, SNS, Lambda, IAM — stays within the free tier for this level of usage.

Delete the Grafana stack after the demo to stop billing:

```bash
aws cloudformation delete-stack \
  --stack-name dev-grafana \
  --region ap-southeast-1
```

---

## Technologies

AWS Managed Grafana, CloudFormation, CloudWatch, SNS, Lambda, IAM Identity Center, GitHub Actions, Python 3.12, Bash
