#!/usr/bin/env bash
# Convert every Keycloak table to the *database default* charset/collation.
# Required before Keycloak 26.7 Liquibase if tables are still latin1 (or mixed).
#
# Env:
#   MYSQL_HOST MYSQL_USER MYSQL_DATABASE
#   MYSQL_PWD            (never echo)
#   DRY_RUN=1            print ALTER statements only
#   DROP_PARTIAL_VCRED=1 drop USER_VER_CREDENTIAL if it exists and 26.7.0-verifiable-credential
#                        is not in DATABASECHANGELOG (failed mid-changeset leftover)
set -euo pipefail

: "${MYSQL_HOST:?}"
: "${MYSQL_USER:?}"
: "${MYSQL_DATABASE:?}"

mysql_cmd() {
  mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" --database="$MYSQL_DATABASE" "$@"
}

echo "=== before ==="
mysql_cmd --table -e \
  "SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
   FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = DATABASE();"
mysql_cmd --table -e \
  "SELECT TABLE_COLLATION, COUNT(*) AS tables
   FROM information_schema.TABLES
   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
   GROUP BY TABLE_COLLATION;"

DEFAULT_COLLATION=$(mysql_cmd --batch --skip-column-names -e \
  "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = DATABASE();")
DEFAULT_CHARSET=$(mysql_cmd --batch --skip-column-names -e \
  "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = DATABASE();")

if [ -z "$DEFAULT_COLLATION" ] || [ -z "$DEFAULT_CHARSET" ]; then
  echo "could not read schema default charset/collation" >&2
  exit 1
fi
echo "target: ${DEFAULT_CHARSET} / ${DEFAULT_COLLATION}"

mysql_cmd --batch --skip-column-names -e \
  "SELECT CONCAT('ALTER TABLE \`', TABLE_NAME, '\` CONVERT TO CHARACTER SET ${DEFAULT_CHARSET} COLLATE ${DEFAULT_COLLATION};')
   FROM information_schema.TABLES
   WHERE TABLE_SCHEMA = DATABASE()
     AND TABLE_TYPE = 'BASE TABLE'
     AND TABLE_COLLATION <> '${DEFAULT_COLLATION}';" > /tmp/alters.sql

echo "alter statements: $(wc -l < /tmp/alters.sql | tr -d ' ')"
cat /tmp/alters.sql

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN=1 — not applying"
  exit 0
fi

{
  echo "SET FOREIGN_KEY_CHECKS=0;"
  cat /tmp/alters.sql
  echo "SET FOREIGN_KEY_CHECKS=1;"
} > /tmp/run.sql

mysql_cmd < /tmp/run.sql

if [ "${DROP_PARTIAL_VCRED:-0}" = "1" ]; then
  EXISTS=$(mysql_cmd --batch --skip-column-names -e \
    "SELECT COUNT(*) FROM information_schema.TABLES
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'USER_VER_CREDENTIAL';")
  RAN=$(mysql_cmd --batch --skip-column-names -e \
    "SELECT COUNT(*) FROM DATABASECHANGELOG WHERE ID = '26.7.0-verifiable-credential';")
  if [ "$EXISTS" = "1" ] && [ "$RAN" = "0" ]; then
    echo "dropping leftover USER_VER_CREDENTIAL (table exists, changeset not recorded)"
    mysql_cmd -e "DROP TABLE IF EXISTS USER_VER_CREDENTIAL;"
  else
    echo "skip USER_VER_CREDENTIAL drop (exists=${EXISTS} changeset_ran=${RAN})"
  fi
fi

echo "=== after ==="
mysql_cmd --table -e \
  "SELECT TABLE_COLLATION, COUNT(*) AS tables
   FROM information_schema.TABLES
   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
   GROUP BY TABLE_COLLATION;"

MISMATCH=$(mysql_cmd --batch --skip-column-names -e \
  "SELECT COUNT(*) FROM information_schema.TABLES
   WHERE TABLE_SCHEMA = DATABASE()
     AND TABLE_TYPE = 'BASE TABLE'
     AND TABLE_COLLATION <> '${DEFAULT_COLLATION}';")
if [ "$MISMATCH" != "0" ]; then
  echo "ERROR: ${MISMATCH} tables still not ${DEFAULT_COLLATION}" >&2
  exit 1
fi

echo "CHARSET_FIX_DONE"
