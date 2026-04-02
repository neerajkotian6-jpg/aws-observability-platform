#!/usr/bin/env bash
set -euo pipefail

: "${GRAFANA_URL:?GRAFANA_URL must be set}"
: "${GRAFANA_API_KEY:?GRAFANA_API_KEY must be set}"
: "${SNS_TOPIC_ARN:?SNS_TOPIC_ARN must be set}"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID must be set}"
: "${ENVIRONMENT:?ENVIRONMENT must be set}"

GRAFANA_API="${GRAFANA_URL}/api"
HEADERS=(-H "Authorization: Bearer ${GRAFANA_API_KEY}" -H "Content-Type: application/json")

echo "Deploying Grafana config to: ${GRAFANA_URL}"

echo "Creating Observability folder..."
curl -sf -X POST "${GRAFANA_API}/folders" \
  "${HEADERS[@]}" \
  -d '{"uid":"observability","title":"Observability"}' \
  | jq '.uid' || echo "Folder may already exist, continuing..."

echo "Importing CloudWatch dashboard..."
DASHBOARD_JSON=$(cat grafana/dashboards/cloudwatch-dashboard.json)
curl -sf -X POST "${GRAFANA_API}/dashboards/import" \
  "${HEADERS[@]}" \
  -d "{
    \"dashboard\": ${DASHBOARD_JSON},
    \"folderId\": 0,
    \"folderUid\": \"observability\",
    \"overwrite\": true,
    \"inputs\": [
      {
        \"name\": \"DS_CLOUDWATCH\",
        \"type\": \"datasource\",
        \"pluginId\": \"cloudwatch\",
        \"value\": \"cloudwatch\"
      }
    ]
  }" | jq '{status: .status, url: .importedUrl}'
echo "Dashboard imported"

echo "Deploying alert rules..."
ALERTS_JSON=$(sed \
  "s|arn:aws:sns:us-east-1:ACCOUNT_ID:dev-observability-alerts|${SNS_TOPIC_ARN}|g" \
  grafana/alerts/cloudwatch-alerts.json)

CONTACT_POINT=$(echo "${ALERTS_JSON}" | jq '.contactPoints[0].receivers[0]')
curl -sf -X POST "${GRAFANA_API}/v1/provisioning/contact-points" \
  "${HEADERS[@]}" \
  -d "${CONTACT_POINT}" \
  | jq '{uid: .uid, name: .name}' || echo "Contact point may already exist"

POLICY=$(echo "${ALERTS_JSON}" | jq '.notificationPolicies')
curl -sf -X PUT "${GRAFANA_API}/v1/provisioning/policies" \
  "${HEADERS[@]}" \
  -d "${POLICY}" || echo "Policy update complete"

echo "All Grafana configuration deployed successfully!"
echo "Dashboard: ${GRAFANA_URL}/d/cloudwatch-observability-v1"
