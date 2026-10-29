#!/usr/bin/env bash
# Read-only Keycloak MySQL inspect. Prints collation mix and 26.6/26.7 Liquibase rows.
# Env: MYSQL_HOST MYSQL_USER MYSQL_DATABASE  (and MYSQL_PWD, never echo it)
set -euo pipefail

: "${MYSQL_HOST:?}"
: "${MYSQL_USER:?}"
: "${MYSQL_DATABASE:?}"

mysql_cmd() {
  mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" --database="$MYSQL_DATABASE" "$@"
}

echo "=== schema default ==="
mysql_cmd --table -e \
  "SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
   FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = DATABASE();"

echo "=== table collations ==="
mysql_cmd --table -e \
  "SELECT TABLE_COLLATION, COUNT(*) AS tables
   FROM information_schema.TABLES
   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
   GROUP BY TABLE_COLLATION ORDER BY tables DESC;"

echo "=== KEYCLOAK_GROUP.ORG_ID ==="
mysql_cmd --table -e \
  "SELECT COLUMN_NAME, CHARACTER_SET_NAME, COLLATION_NAME
   FROM information_schema.COLUMNS
   WHERE TABLE_SCHEMA = DATABASE()
     AND TABLE_NAME = 'KEYCLOAK_GROUP'
     AND COLUMN_NAME = 'ORG_ID';"

echo "=== USER_VER_CREDENTIAL present? ==="
mysql_cmd --table -e \
  "SELECT TABLE_NAME, TABLE_COLLATION
   FROM information_schema.TABLES
   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'USER_VER_CREDENTIAL';"

echo "=== Liquibase 26.6 / 26.7 ==="
mysql_cmd --table -e \
  "SELECT ID, DATEEXECUTED, EXECTYPE
   FROM DATABASECHANGELOG
   WHERE ID LIKE '26.6.0%' OR ID LIKE '26.7.0%'
   ORDER BY DATEEXECUTED, ID;"

echo "INSPECT_DONE"
