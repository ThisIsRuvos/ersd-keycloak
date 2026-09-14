# Production upgrade runbook: ERSD Keycloak 26.7.3

Production cutover only. Building the image and proving it locally are out of scope; use an image that is already in the production ECR repository.

This upgrades the live Keycloak service from the current production revision (expected **26.0.x**, same lineage as sandbox) to **26.7.3**, after a MySQL backup and, if needed, a charset conversion. Liquibase then applies the 26.6 / 26.7 schema changes on first boot.

Do **not** start Phase 4 or later without a verified RDS snapshot from Phase 2. Liquibase and charset conversion are the hard-to-reverse steps.

Treat the Keycloak database as sensitive (usernames, emails, realm config). Keep backups in AWS. Do not download dumps to laptops or paste query results that include user rows into tickets or chat.

---

## 1. What this change does

| Area | Change |
| --- | --- |
| Container | Pre-built `ersd/ersd-keycloak` tag based on Keycloak 26.7.3 (patched jars, idempotent `ORG_ID` changeset) |
| Schema | Keycloak 26.6 / 26.7 Liquibase migrations on first start |
| Database charset | If existing tables are `latin1` (or any collation other than the database default), convert them to match **before** the new task runs Liquibase. Sandbox was `latin1_swedish_ci` tables vs database default `utf8mb4_0900_ai_ci` |

**Prerequisite:** the new image tag is already in production ECR. Record it on the worksheet as `IMAGE_TAG`.

---

## 2. Production worksheet

Fill this in from the **production** account before the window. Sandbox values are the proven reference only.

| Parameter | Production (fill in) | Sandbox reference (do not use for prod) |
| --- | --- | --- |
| AWS CLI profile | | `sandbox` |
| Account ID | | `703861148810` |
| Region | | `us-east-1` |
| ECS cluster | | `BS-test` |
| ECS service | | `ERSD-KEYCLOAK` |
| Task definition family | | `ERSD-KeyCloak` |
| Current healthy revision | | `:31` was 26.0.2 before the test upgrade |
| Container name | | `ERSD-KC` |
| ECR registry | | `703861148810.dkr.ecr.us-east-1.amazonaws.com` |
| ECR repository | | `ersd/ersd-keycloak` |
| New image tag (already in ECR) | | `26.7.3-3` (single linux/amd64 manifest) |
| RDS instance ID | | `ersd-keycloak` |
| RDS engine | MySQL 8.0.x | MySQL `8.0.45` |
| DB name | | `keycloak` |
| CloudWatch log group | | `/ecs/ERSD-KeyCloak` |
| Target group ARN | | `.../targetgroup/ERSD-KEYCLOAK/062e7baf4f4a5457` |
| Public / admin URL | | (ALB in front of `/auth`) |
| Known-good prior image tag | | `26.0.2` |
| Maintenance window owner + comms | | |

Export once filled in:

```bash
export AWS_PROFILE=<prod-profile>
export AWS_REGION=us-east-1
export CLUSTER=<prod-cluster>
export SERVICE=<prod-service>
export TD_FAMILY=<prod-task-family>
export ECR=<account>.dkr.ecr.us-east-1.amazonaws.com/ersd/ersd-keycloak
export IMAGE_TAG=<already-pushed-tag>
export RDS_ID=<prod-rds-instance-id>
export LOG_GROUP=<prod-log-group>
export TG_ARN=<prod-target-group-arn>
```

Verify identity **before every AWS mutation**:

```bash
aws sts get-caller-identity
```

Stop if the account ID is not the production account on the worksheet.

---

## 3. Risks, downtime, and decision points

- **Downtime is required** for charset conversion and for the first 26.7.3 boot (Liquibase). Plan a maintenance window. Sandbox first boot after convert took about 1–2 minutes of Quarkus build plus ~40–60 seconds of Liquibase; allow **15–30 minutes** in production.
- **Do not** run the new image against a mixed-charset MySQL schema. New tables inherit the database default (`utf8mb4_0900_ai_ci` in sandbox). Foreign keys then fail with `are incompatible`.
- After Liquibase has applied 26.6/26.7 changesets, the **only** safe application backout is: restore the snapshot, then deploy the previous task definition. Rolling the old image onto a half-migrated schema will fail.
- Charset conversion without a later Liquibase run is usually compatible with Keycloak 26.0.x, but if conversion errors or looks wrong, restore the snapshot anyway.

---

## 4. Phase 0 — Freeze, inventory, baseline

### 0.1 Confirm account and that the image exists

```bash
aws sts get-caller-identity

aws ecr describe-images --repository-name ersd/ersd-keycloak --region "$AWS_REGION" \
  --image-ids imageTag="$IMAGE_TAG" \
  --query 'imageDetails[0].{tags:imageTags,pushed:imagePushedAt,digest:imageDigest}' \
  --output json

aws ecr batch-get-image --repository-name ersd/ersd-keycloak --region "$AWS_REGION" \
  --image-ids imageTag="$IMAGE_TAG" \
  --accepted-media-types \
    'application/vnd.docker.distribution.manifest.v2+json' \
    'application/vnd.oci.image.manifest.v1+json' \
    'application/vnd.docker.distribution.manifest.list.v2+json' \
    'application/vnd.oci.image.index.v1+json' \
  --query 'images[0].imageManifest' --output text \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("mediaType")); print("child_manifests", len(d.get("manifests") or []))'
```

**Check:** account ID matches the worksheet. The tag exists; record the digest. The manifest must be a **single** image (`application/vnd.oci.image.manifest.v1+json` or Docker v2), **not** an OCI index / manifest list (`child_manifests` must be `0`). An index with `unknown/unknown` attestation sub-images breaks copying the tag into production.

**Backout:** stop. Do not deploy that tag. Use a linux/amd64 image built with `--provenance=false --sbom=false`.

**Backout:** stop. No AWS or database changes have been made.

### 0.2 Record the live production baseline

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$AWS_REGION" \
  --query 'services[0].{status:status,desired:desiredCount,running:runningCount,taskDef:taskDefinition,rollout:deployments[0].rolloutState}' \
  --output json

aws ecs describe-task-definition --task-definition "$TD_FAMILY" --region "$AWS_REGION" \
  --query 'taskDefinition.{arn:taskDefinitionArn,rev:revision,image:containerDefinitions[0].image,cpu:cpu,memory:memory,env:containerDefinitions[0].environment[*].name}' \
  --output json

aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --region "$AWS_REGION" \
  --query 'DBInstances[0].{id:DBInstanceIdentifier,status:DBInstanceStatus,eng:Engine,ver:EngineVersion,multi:MultiAZ,ret:BackupRetentionPeriod,win:PreferredBackupWindow,endpoint:Endpoint.Address}' \
  --output json

aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region "$AWS_REGION" \
  --query 'TargetHealthDescriptions[].{id:Target.Id,port:Target.Port,state:TargetHealth.State}' \
  --output table
```

Write down:

- Current task definition ARN and revision (`OLD_TD`)
- Current image tag (`OLD_IMAGE`)
- RDS endpoint
- Backup retention (need ≥ 1 day so point-in-time restore remains available)
- Target health = `healthy`

```bash
export OLD_TD=arn:aws:ecs:${AWS_REGION}:<account>:task-definition/${TD_FAMILY}:<rev>
export OLD_IMAGE=...
export SNAPSHOT_ID=${RDS_ID}-pre-26-7-3-$(date -u +%Y%m%d%H%M)
```

**Check:** service is steady, targets healthy, you can log in to the production admin console and an ERSD client can obtain a token.

**Backout:** stop. Nothing changed.

---

## 5. Phase 1 — Database backup (required before any schema change)

Do this while the **current** Keycloak is still the old, healthy revision. That gives you a snapshot that matches `OLD_TD`.

### 1.1 Confirm automated backups are on

```bash
aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --region "$AWS_REGION" \
  --query 'DBInstances[0].{ret:BackupRetentionPeriod,latest:LatestRestorableTime,win:PreferredBackupWindow}' \
  --output json
```

**Check:** `BackupRetentionPeriod` ≥ 1. Note `LatestRestorableTime` (PITR fallback).

**Backout:** if retention is 0, enable backups and wait for the first automated snapshot before continuing. Do not proceed to charset conversion.

### 1.2 Create a manual snapshot

```bash
aws rds create-db-snapshot \
  --db-instance-identifier "$RDS_ID" \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --region "$AWS_REGION" \
  --tags Key=purpose,Value=pre-keycloak-26.7.3 Key=service,Value=ERSD-KEYCLOAK
```

Wait until available (often 5–20 minutes; large DBs take longer):

```bash
aws rds wait db-snapshot-available \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --region "$AWS_REGION"

aws rds describe-db-snapshots --db-snapshot-identifier "$SNAPSHOT_ID" --region "$AWS_REGION" \
  --query 'DBSnapshots[0].{id:DBSnapshotIdentifier,status:Status,pct:PercentProgress,created:SnapshotCreateTime,engine:Engine,ver:EngineVersion}' \
  --output json
```

**Check:** `Status` is `available` and `PercentProgress` is `100`. Record the snapshot ARN.

Optional extra copy (another region or account) if that is your DR standard:

```bash
aws rds copy-db-snapshot \
  --source-db-snapshot-identifier "$SNAPSHOT_ID" \
  --target-db-snapshot-identifier "${SNAPSHOT_ID}-copy" \
  --region "$AWS_REGION"
```

Do **not** rely on a laptop `mysqldump`. The instance is private; a dump also copies user identifiers out of the account.

**Backout if snapshot never becomes available:** do not continue. Keycloak is still on the old task definition. Investigate snapshot/KMS/storage. No schema has been changed.

### 1.3 Confirm you can restore (paper check)

You do not have to restore now. Confirm the restore command you will use if Phase 4 or 6 fails, and that IAM allows it. Restore creates a **new** instance by default. In-place rollback is: restore to `<rds-id>-restored`, flip `KC_DB_URL_HOST`, or rename instances. Decide that procedure **now** and write it on the worksheet (see [Appendix A](#appendix-a--backout-catalog)).

**Check:** team agrees on the restore naming and who runs it.

**Backout:** stop the window. Snapshot is unused; old service stays up.

---

## 6. Phase 2 — Inspect production schema (read-only)

RDS is not public. Run a short-lived MySQL client task on the **same cluster / AZ / security-group path** Keycloak already uses. Reuse Keycloak’s DB host, database, and username from the current task definition (do not print the password).

Inspect only aggregates — not user rows:

```sql
SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = DATABASE();

SELECT TABLE_COLLATION, COUNT(*) AS tables
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
GROUP BY TABLE_COLLATION;

SELECT COLUMN_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME = 'KEYCLOAK_GROUP'
  AND COLUMN_NAME = 'ORG_ID';

SELECT ID FROM DATABASECHANGELOG
WHERE ID LIKE '26.6.0%' OR ID LIKE '26.7.0%'
ORDER BY DATEEXECUTED;
```

**Check / decide:**

| Finding | Action |
| --- | --- |
| All tables already match the schema default (`utf8mb4_...`) | Skip Phase 4 conversion. Keep the snapshot. Continue to Phase 3 + 5 |
| Mix of `latin1_*` and `utf8mb4_*` (sandbox case: 86 + 5) | Phase 4 is **mandatory** |
| `KEYCLOAK_GROUP.ORG_ID` exists | Expected if production is 26.0.x. The image precondition will `MARK_RAN` |
| `26.7.0-*` rows already in `DATABASECHANGELOG` | Stop. Someone already migrated. Re-evaluate; do not convert/drop tables blindly |

**Backout:** if the inspect task fails to connect, fix networking/SG. Do not guess charset. Old Keycloak remains up.

Deregister the inspect task definition when finished so it does not keep DB credentials around longer than needed.

---

## 7. Phase 3 — Take Keycloak out of service

Announce the window. Then scale to zero so nothing writes while you convert or migrate.

```bash
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count 0 --region "$AWS_REGION"

aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$AWS_REGION"

aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$AWS_REGION" \
  --query 'services[0].{desired:desiredCount,running:runningCount}' --output json
```

**Check:** `desired` and `running` are `0`. Target group has no healthy Keycloak targets (or they are draining).

**Backout:**

```bash
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$OLD_TD" --desired-count 1 --region "$AWS_REGION"
```

Wait until targets are healthy and login works. Database is still the pre-change snapshot-compatible schema if you have not started Phase 4.

---

## 8. Phase 4 — Convert table charset / collation

Only if Phase 2 showed a mismatch. Target collation must be the **database default** (sandbox: `utf8mb4_0900_ai_ci`), not a different utf8mb4 collation.

### 4.1 Convert

Run a one-off ECS task (same pattern as sandbox `tmp-ersd-mysql-charset`) with a script equivalent to:

```bash
set -euo pipefail
mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" --database="$MYSQL_DATABASE" \
  --batch --skip-column-names -e \
  "SELECT TABLE_COLLATION, COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' GROUP BY TABLE_COLLATION;"

mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" --database="$MYSQL_DATABASE" \
  --batch --skip-column-names -e \
  "SELECT CONCAT('ALTER TABLE \`', TABLE_NAME, '\` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;') FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' AND TABLE_COLLATION <> 'utf8mb4_0900_ai_ci';" \
  > /tmp/alters.sql

wc -l /tmp/alters.sql
{ echo 'SET FOREIGN_KEY_CHECKS=0;'; cat /tmp/alters.sql; echo 'SET FOREIGN_KEY_CHECKS=1;'; } > /tmp/run.sql
mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" --database="$MYSQL_DATABASE" < /tmp/run.sql

# Only if a prior failed 26.7 start created this table without the FK:
mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" --database="$MYSQL_DATABASE" \
  -e "DROP TABLE IF EXISTS USER_VER_CREDENTIAL;"

mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" --database="$MYSQL_DATABASE" \
  --batch --skip-column-names -e \
  "SELECT TABLE_COLLATION, COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' GROUP BY TABLE_COLLATION;"
echo CHARSET_FIX_DONE
```

Replace `utf8mb4_0900_ai_ci` with the actual `DEFAULT_COLLATION_NAME` from Phase 2 if it differs.

Do not print `MYSQL_PWD`. Deregister the one-off task definition after the run.

### 4.2 Verify conversion

**Check:**

- Task exit code `0`
- Logs contain `CHARSET_FIX_DONE`
- Collation summary is a **single** `utf8mb4_*` bucket equal to the schema default
- Table count is sane (sandbox ended at 90 tables after dropping an empty partial `USER_VER_CREDENTIAL`)

**Backout if conversion fails or counts look wrong:**

1. Leave `desired-count` at 0.
2. Restore the Phase 1 snapshot (Appendix A).
3. Point Keycloak at the restored instance if the identifier changed.
4. Deploy `$OLD_TD` with `--desired-count 1`.
5. Verify login and ERSD token as in Phase 7.
6. Stop the window. Do not retry conversion until the failure is understood.

If conversion succeeded but you decide not to upgrade the image tonight:

```bash
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$OLD_TD" --desired-count 1 --region "$AWS_REGION"
```

26.0.x can run on utf8mb4. Prefer restoring the snapshot if anything about the convert was uncertain.

---

## 9. Phase 5 — Register and apply the new task definition

### 5.1 Register

Copy the **current production** task definition. Change **only** the image to `${ECR}:${IMAGE_TAG}`. Keep environment names, roles, CPU, memory, port 8080, log group, and placement constraints.

```bash
aws ecs describe-task-definition --task-definition "$TD_FAMILY" --region "$AWS_REGION" --output json \
  | python3 -c '
import json, sys, os
raw = json.load(sys.stdin)["taskDefinition"]
drop = {"taskDefinitionArn","revision","status","requiresAttributes","compatibilities","registeredAt","registeredBy","deregisteredAt"}
td = {k:v for k,v in raw.items() if k not in drop}
td["containerDefinitions"][0]["image"] = os.environ["ECR"] + ":" + os.environ["IMAGE_TAG"]
open("/tmp/ersd-kc-new-td.json","w").write(json.dumps(td))
print("image", td["containerDefinitions"][0]["image"])
print("env_names", [e["name"] for e in td["containerDefinitions"][0]["environment"]])
'

aws ecs register-task-definition --cli-input-json file:///tmp/ersd-kc-new-td.json --region "$AWS_REGION" \
  --query 'taskDefinition.{arn:taskDefinitionArn,rev:revision,image:containerDefinitions[0].image}' \
  --output json

rm -f /tmp/ersd-kc-new-td.json
export NEW_TD=${TD_FAMILY}:<new-revision>
```

**Check:** printed image tag is `${IMAGE_TAG}`. Environment **names** match the old revision (do not dump values).

**Backout:** do not update the service. The new revision is unused. Scale `$OLD_TD` back to 1 if still at 0.

### 5.2 Deploy

```bash
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$NEW_TD" --desired-count 1 --force-new-deployment \
  --region "$AWS_REGION"
```

### 5.3 Verify during deployment

Watch the service and logs until bootstrap finishes (often several minutes on first start):

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$AWS_REGION" \
  --query 'services[0].{running:runningCount,pending:pendingCount,desired:desiredCount,taskDef:taskDefinition,failed:deployments[0].failedTasks,rollout:deployments[0].rolloutState,event:events[0].message}' \
  --output json

aws logs tail "$LOG_GROUP" --since 10m --region "$AWS_REGION" --format short
```

First start will log `Changes detected in configuration` and a Quarkus build, then `Updating database`, then `Bootstrap completed`.

**Check (all required before calling the deploy successful):**

- Running task uses `$NEW_TD` and `${IMAGE_TAG}`
- Logs: `Keycloak 26.7.3` and `Bootstrap completed`
- No `Failed to start server`
- No `Duplicate column name 'ORG_ID'`
- No `foreign key ... are incompatible`
- `failedTasks` stays `0`
- Rollout becomes `COMPLETED` and the service reaches a steady state
- Target group: `healthy` on container port 8080

```bash
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region "$AWS_REGION" \
  --query 'TargetHealthDescriptions[].{id:Target.Id,port:Target.Port,state:TargetHealth.State}' \
  --output table
```

**Backout if the new task crash-loops or Liquibase fails:**

1. Scale to 0 immediately so it stops retrying migrations.

   ```bash
   aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
     --desired-count 0 --region "$AWS_REGION"
   ```

2. Restore the Phase 1 snapshot (Appendix A). Do not redeploy `$OLD_TD` onto a partially migrated schema.

3. Deploy `$OLD_TD` with `--desired-count 1`.

4. Verify Phase 7 on the **old** version.

5. Leave the failed `$NEW_TD` unused. Keep the snapshot.

---

## 10. Phase 6 — Functional verification (after deploy)

Use production URLs from the worksheet. Do not dump tokens or user lists into the run log.

1. `GET https://<host>/auth/realms/master` → 200
2. `GET https://<host>/auth/realms/master/.well-known/openid-configuration` → JSON issuer under `/auth`
3. Repeat for the `ersd` realm (or the production realm name)
4. Open the admin console; log in with a break-glass admin
5. From the ERSD app (or a one-off authorization-code / client-credentials test you already use), obtain a token and hit one authenticated API
6. Confirm the ERSD login theme still loads
7. Spot-check CloudWatch for errors for 10–15 minutes

**Check:** all of the above pass. ERSD portal login works.

**Backout:** same as Phase 5 (scale 0 → restore snapshot → `$OLD_TD` → verify). A “mostly up” Keycloak with a failed realm or theme is still a rollback.

---

## 11. Phase 7 — Close the window

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$AWS_REGION" \
  --query 'services[0].{running:runningCount,desired:desiredCount,taskDef:taskDefinition,rollout:deployments[0].rolloutState,event:events[0].message}' \
  --output json

aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region "$AWS_REGION" \
  --query 'TargetHealthDescriptions[].{state:TargetHealth.State,port:Target.Port}' --output table
```

Record in the change ticket (no secrets, no user data):

- New task definition ARN
- Image tag + digest
- Snapshot ID
- Window start/end
- Verification results

Keep `$SNAPSHOT_ID` until you are past the agreed soak (recommend **7 days**, matching typical RDS retention). Deregister one-off MySQL client task definitions.

---

## Appendix A — Backout catalog

Use the **earliest** matching row. Always scale Keycloak to 0 before a snapshot restore.

| When it failed | Data plane | Application plane | Verify |
| --- | --- | --- | --- |
| Phase 0 (image missing / wrong account) | No DB change | Nothing to revert | n/a |
| Phase 1 snapshot failed | No DB change | Keep `$OLD_TD` at desired 1 | Login + token |
| Phase 2 inspect failed | No DB change | Keep `$OLD_TD` | Login + token |
| Phase 3 scale-to-0 only | No DB change | `--task-definition $OLD_TD --desired-count 1` | Target healthy, login |
| Phase 4 charset failed or suspicious | Restore `$SNAPSHOT_ID` | `$OLD_TD` desired 1 | Phase 6 on old version |
| Phase 4 charset OK, abort before deploy | Optional restore (preferred if unsure); utf8mb4-only is usually OK for 26.0.x | `$OLD_TD` desired 1 | Phase 6 on old version |
| Phase 5 Liquibase / task failed | **Restore `$SNAPSHOT_ID`** (required) | `$OLD_TD` desired 1 | Phase 6 on old version |
| Phase 6 functional failure after Bootstrap completed | **Restore `$SNAPSHOT_ID`** | `$OLD_TD` desired 1 | Phase 6 on old version |

### Restore snapshot to a new instance

```bash
export RESTORED_ID=${RDS_ID}-restored-$(date -u +%Y%m%d%H%M)

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "$RESTORED_ID" \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --region "$AWS_REGION"

aws rds wait db-instance-available --db-instance-identifier "$RESTORED_ID" --region "$AWS_REGION"

aws rds describe-db-instances --db-instance-identifier "$RESTORED_ID" --region "$AWS_REGION" \
  --query 'DBInstances[0].{status:DBInstanceStatus,endpoint:Endpoint.Address}' --output json
```

Copy the restored instance’s VPC / SG / subnet settings from the original if the restore did not inherit them. Register a task definition that is `$OLD_TD` plus `KC_DB_URL_HOST` = restored endpoint. Scale to 1. Verify Phase 6.

Do not delete the failed/migrated instance until login works on the restored one.

### Point-in-time restore (only if the manual snapshot is unusable)

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$RDS_ID" \
  --target-db-instance-identifier "${RDS_ID}-pitr" \
  --restore-time "<LatestRestorableTime from Phase 1, or just before charset start>" \
  --region "$AWS_REGION"
```

Prefer the **manual** snapshot. PITR is the fallback.

---

## Appendix B — Failure signatures (from sandbox)

| Log / SQL | Meaning | Action |
| --- | --- | --- |
| `Duplicate column name 'ORG_ID'` on `jpa-changelog-26.6.0.xml::26.6.0-org-group-relationship` | Column already present; image is missing the idempotent precondition | Scale to 0; restore snapshot; do not keep retrying that image |
| `FK_GROUP_ORGANIZATION` / `FK_VCRED_USER` `are incompatible` | Charset/collation mix (`latin1` vs `utf8mb4`) | Scale to 0; restore snapshot; complete Phase 4 before retrying |
| `Failed to start server in (production) mode` + `Failed to update database` | Liquibase abort; MySQL may have committed earlier DDL | Scale to 0; restore snapshot; do not keep retrying |
| ECS `minHealthyPercent` 100 and 1 task | New revision waits for a second slot | Scale to 0 first (this runbook) or temporarily lower min healthy during the window |

---

## Appendix C — Sandbox proof (reference)

Completed 2026-09-14 on account `703861148810`, profile `sandbox`:

- Image (transfer this tag): `703861148810.dkr.ecr.us-east-1.amazonaws.com/ersd/ersd-keycloak:26.7.3-3` — single `linux/amd64` Docker v2 manifest, no attestation index
- Running sandbox service still references `26.7.3-2` (same layers; that tag is an OCI index and should not be copied to prod)
- Task definition: `ERSD-KeyCloak:34`
- Service: `arn:aws:ecs:us-east-1:703861148810:service/BS-test/ERSD-KEYCLOAK`
- Prior healthy image: `26.0.2` (`ERSD-KeyCloak:31`)
- RDS: `ersd-keycloak` (MySQL 8.0.45). 86 tables `latin1_swedish_ci`, 5 already `utf8mb4_0900_ai_ci`; converted to 90 tables `utf8mb4_0900_ai_ci`
- After cutover: rollout `COMPLETED`, ALB target `healthy` on 8080, `Bootstrap completed`

Production must repeat the worksheet and backups even though sandbox succeeded. Do not point production at the sandbox RDS or sandbox task definition.
