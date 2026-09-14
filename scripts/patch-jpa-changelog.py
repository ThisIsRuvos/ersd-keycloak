#!/usr/bin/env python3
"""Make Keycloak 26.6.0 ORG_ID migration idempotent for 26.0.x MySQL upgrades.

A prior 26.7 start can leave KEYCLOAK_GROUP.ORG_ID in place (MySQL commits DDL
outside Liquibase transactions) without a DATABASECHANGELOG row. The upstream
changeset also cannot add FK_GROUP_ORGANIZATION on older MySQL schemas whose
ORG.ID charset/collation does not match KEYCLOAK_GROUP.ORG_ID. Skipping the
whole changeset when the column already exists lets the server start; the
organization feature still works without that FK.
"""
import sys
from pathlib import Path

p = Path(sys.argv[1])
text = p.read_text()
old = """    <changeSet author=\"keycloak\" id=\"26.6.0-org-group-relationship\">
        <addColumn tableName=\"KEYCLOAK_GROUP\">
            <column name=\"ORG_ID\" type=\"VARCHAR(255)\"/>
        </addColumn>"""
new = """    <changeSet author=\"keycloak\" id=\"26.6.0-org-group-relationship\">
        <preConditions onSqlOutput=\"TEST\" onFail=\"MARK_RAN\">
            <not>
                <columnExists tableName=\"KEYCLOAK_GROUP\" columnName=\"ORG_ID\"/>
            </not>
        </preConditions>
        <addColumn tableName=\"KEYCLOAK_GROUP\">
            <column name=\"ORG_ID\" type=\"VARCHAR(255)\"/>
        </addColumn>"""
if old not in text:
    raise SystemExit("26.6.0-org-group-relationship block not found")
p.write_text(text.replace(old, new, 1))
print("patched", p)
