#!/usr/bin/env bash
# Run inspect-keycloak-schema.sh or convert-keycloak-charset.sh as a one-off
# ECS task on the same cluster as Keycloak (RDS is not public).
#
# Usage:
#   AWS_PROFILE=... CLUSTER=... TD_FAMILY=... LOG_GROUP=... \
#     ./scripts/run-mysql-oneoff.sh inspect
#   AWS_PROFILE=... CLUSTER=... TD_FAMILY=... LOG_GROUP=... \
#     DROP_PARTIAL_VCRED=1 ./scripts/run-mysql-oneoff.sh convert
#   AWS_PROFILE=... CLUSTER=... TD_FAMILY=... LOG_GROUP=... \
#     DRY_RUN=1 ./scripts/run-mysql-oneoff.sh convert
#
# Copies DB host/user/password from the current Keycloak task definition.
# Does not print the password.
set -euo pipefail

: "${AWS_PROFILE:?}"
: "${AWS_REGION:=us-east-1}"
: "${CLUSTER:?}"
: "${TD_FAMILY:?}"
: "${LOG_GROUP:?}"

MODE="${1:?usage: $0 inspect|convert}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$MODE" in
  inspect) SCRIPT_PATH="$ROOT/scripts/inspect-keycloak-schema.sh" ;;
  convert) SCRIPT_PATH="$ROOT/scripts/convert-keycloak-charset.sh" ;;
  *) echo "usage: $0 inspect|convert" >&2; exit 1 ;;
esac

SCRIPT_B64=$(base64 < "$SCRIPT_PATH" | tr -d '\n')

python3 - "$MODE" "$SCRIPT_B64" <<'PY'
import json, os, sys, subprocess

mode, script_b64 = sys.argv[1], sys.argv[2]
env = os.environ
raw = json.loads(subprocess.check_output([
    "aws", "ecs", "describe-task-definition",
    "--task-definition", env["TD_FAMILY"],
    "--region", env["AWS_REGION"],
    "--output", "json",
], env=env))["taskDefinition"]
td_env = {e["name"]: e["value"] for e in raw["containerDefinitions"][0]["environment"]}
needed = ["KC_DB_URL_HOST", "KC_DB_URL_DATABASE", "KC_DB_USERNAME", "KC_DB_PASSWORD"]
missing = [k for k in needed if k not in td_env]
if missing:
    raise SystemExit("task definition missing " + ",".join(missing))

inner = """set -euo pipefail
echo '{script_b64}' | base64 -d > /tmp/kc-schema.sh
chmod +x /tmp/kc-schema.sh
export DRY_RUN='{dry}'
export DROP_PARTIAL_VCRED='{vcred}'
/tmp/kc-schema.sh
""".format(
    script_b64=script_b64,
    dry=os.environ.get("DRY_RUN", "0"),
    vcred=os.environ.get("DROP_PARTIAL_VCRED", "0"),
)

td = {
    "family": "tmp-ersd-mysql-charset",
    "requiresCompatibilities": raw.get("requiresCompatibilities") or ["EC2"],
    "cpu": "256",
    "memory": "512",
    "executionRoleArn": raw["executionRoleArn"],
    "placementConstraints": raw.get("placementConstraints") or [],
    "containerDefinitions": [{
        "name": "mysql-client",
        "image": "mysql:8.0",
        "essential": True,
        "environment": [
            {"name": "MYSQL_HOST", "value": td_env["KC_DB_URL_HOST"]},
            {"name": "MYSQL_DATABASE", "value": td_env["KC_DB_URL_DATABASE"]},
            {"name": "MYSQL_USER", "value": td_env["KC_DB_USERNAME"]},
            {"name": "MYSQL_PWD", "value": td_env["KC_DB_PASSWORD"]},
        ],
        "command": ["bash", "-lc", inner],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": env["LOG_GROUP"],
                "awslogs-region": env["AWS_REGION"],
                "awslogs-stream-prefix": f"schema-{mode}",
            },
        },
    }],
}
path = "/tmp/tmp-ersd-mysql-oneoff.json"
json.dump(td, open(path, "w"))
print("wrote", path, "mode", mode)
PY

ARN=$(AWS_PROFILE="$AWS_PROFILE" aws ecs register-task-definition \
  --cli-input-json file:///tmp/tmp-ersd-mysql-oneoff.json \
  --region "$AWS_REGION" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
rm -f /tmp/tmp-ersd-mysql-oneoff.json
echo "registered $ARN"

TASK=$(AWS_PROFILE="$AWS_PROFILE" aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$ARN" \
  --launch-type EC2 \
  --region "$AWS_REGION" \
  --query 'tasks[0].taskArn' --output text)
echo "started $TASK"

for i in $(seq 1 40); do
  LAST=$(AWS_PROFILE="$AWS_PROFILE" aws ecs describe-tasks \
    --cluster "$CLUSTER" --tasks "$TASK" --region "$AWS_REGION" \
    --query 'tasks[0].lastStatus' --output text)
  EXIT=$(AWS_PROFILE="$AWS_PROFILE" aws ecs describe-tasks \
    --cluster "$CLUSTER" --tasks "$TASK" --region "$AWS_REGION" \
    --query 'tasks[0].containers[0].exitCode' --output text)
  echo "poll $i status=$LAST exit=$EXIT"
  if [ "$LAST" = "STOPPED" ]; then
    break
  fi
  sleep 10
done

AWS_PROFILE="$AWS_PROFILE" aws logs tail "$LOG_GROUP" --since 15m --region "$AWS_REGION" --format short \
  | grep -E "schema-${MODE}|INSPECT_DONE|CHARSET_FIX_DONE|ERROR|latin1|utf8|ORG_ID|DRY_RUN|alter statements" || true

AWS_PROFILE="$AWS_PROFILE" aws ecs deregister-task-definition \
  --task-definition "$ARN" --region "$AWS_REGION" \
  --query 'taskDefinition.status' --output text >/dev/null
echo "deregistered $ARN"

if [ "$EXIT" != "0" ]; then
  echo "one-off task failed exit=$EXIT" >&2
  exit 1
fi
