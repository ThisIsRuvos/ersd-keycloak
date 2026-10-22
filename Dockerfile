# Keycloak 26.7.3 remediates CVE-2026-18963 (keycloak-services account takeover)
# and the 26.7.2/26.7.3 server CVEs. Remaining Inspector findings are OS RPMs
# (patched via UBI9 dnf) and third-party jars not yet bumped upstream (overlaid
# below). The 26.6.0 ORG_ID changeset has no precondition and fails when
# upgrading a 26.0.x MySQL schema that already has KEYCLOAK_GROUP.ORG_ID.
# Stage 1: upgrade RPMs inside the Keycloak rootfs using UBI9's dnf
# (the Keycloak image is ubi9-micro based and has no package manager)
FROM registry.access.redhat.com/ubi9:latest AS os-patch

COPY --from=quay.io/keycloak/keycloak:26.7.3 / /mnt/rootfs

RUN dnf -y upgrade --installroot /mnt/rootfs --releasever 9 \
        --setopt=install_weak_deps=0 --nodocs && \
    dnf -y install zip unzip python3 && \
    dnf clean all --installroot /mnt/rootfs && \
    rm -rf /mnt/rootfs/var/cache/dnf /mnt/rootfs/var/log/dnf* /mnt/rootfs/var/log/yum*

# Distrust the eMudhra roots until RHEL ca-certificates drops them (DSO-3028).
# Java reads /etc/pki/ca-trust/extracted/java/cacerts. The Keycloak rootfs is
# UBI micro and its trust binary has no libp11-kit, so the builder p11-kit
# applies the blocklist to a copy of the rootfs anchors and writes the
# regenerated store back. Other emSign roots stay trusted.
# https://emudhra.we-have-a-problem.com/ (Fedora/RHEL workaround)
RUN <<'EOS'
set -euo pipefail

src_anchors=/mnt/rootfs/usr/share/pki/ca-trust-source
src_admin=/mnt/rootfs/etc/pki/ca-trust/source
if [ ! -d "$src_anchors" ] || [ ! -d "$src_admin" ]; then
  echo "Keycloak rootfs is missing the OS trust source" >&2
  exit 1
fi

rm -rf /usr/share/pki/ca-trust-source /etc/pki/ca-trust/source
cp -a "$src_anchors" /usr/share/pki/ca-trust-source
cp -a "$src_admin" /etc/pki/ca-trust/source

blocklist=/etc/pki/ca-trust/source/blocklist
mkdir -p "$blocklist"
extract_root() {
  filter="$1"
  out="$2"
  trust extract --overwrite --format=pem-bundle --filter="$filter" "$out"
  if ! grep -q 'BEGIN CERTIFICATE' "$out"; then
    echo "no certificate extracted for $filter" >&2
    exit 1
  fi
}
extract_root 'pkcs11:object=Comodo%20AAA%20Services%20root;type=cert' \
  "$blocklist/Comodo_AAA_Services_root.pem"
extract_root 'pkcs11:object=emSign%20ECC%20Root%20CA%20-%20G3;type=cert' \
  "$blocklist/emSign_ECC_Root_CA_-_G3.pem"

mkdir -p /mnt/rootfs/etc/pki/ca-trust/source/blocklist
cp -a "$blocklist/." /mnt/rootfs/etc/pki/ca-trust/source/blocklist/

rm -rf /tmp/ca-extracted
update-ca-trust extract -o /tmp/ca-extracted
cp -a /tmp/ca-extracted/. /mnt/rootfs/etc/pki/ca-trust/extracted/

if trust list --filter=ca-anchors | grep -E 'emSign ECC Root CA - G3|Comodo AAA Services root|AAA Certificate Services'; then
  echo "affected roots are still anchors" >&2
  exit 1
fi

aliases=$(chroot /mnt/rootfs /usr/bin/keytool -list -cacerts -storepass changeit)
if printf '%s\n' "$aliases" | grep -q 'emsigneccrootca-g3'; then
  echo "emSign ECC Root CA - G3 is still in Java cacerts" >&2
  exit 1
fi
if printf '%s\n' "$aliases" | grep -q 'aaacertificateservices'; then
  echo "AAA Certificate Services is still in Java cacerts" >&2
  exit 1
fi
echo "CA blocklist applied: emSign ECC Root CA - G3 and Comodo AAA Services root are not anchors"
EOS

# Make 26.6.0-org-group-relationship idempotent, then add the FK/index if missing.
# MySQL commits DDL outside Liquibase transactions, so a prior failed 26.7 start
# can leave ORG_ID in place without a DATABASECHANGELOG row.
COPY scripts/patch-jpa-changelog.py /tmp/patch-jpa-changelog.py
RUN <<'EOS'
set -eu
JAR=$(ls /mnt/rootfs/opt/keycloak/lib/lib/main/org.keycloak.keycloak-model-jpa-*.jar)
mkdir -p /tmp/jpa
cd /tmp/jpa
unzip -qo "$JAR" META-INF/jpa-changelog-26.6.0.xml
python3 /tmp/patch-jpa-changelog.py META-INF/jpa-changelog-26.6.0.xml
zip -q "$JAR" META-INF/jpa-changelog-26.6.0.xml
EOS

# Overlay patched jars. Original filenames are kept because the Quarkus fast-jar
# classpath (lib/quarkus/quarkus-application.dat) references jars by exact path.
# Scanners read the version from the jar's embedded pom.properties.
RUN set -eu; \
    LIB=/mnt/rootfs/opt/keycloak/lib/lib/main; \
    overlay() { \
      prefix="$1"; group_path="$2"; artifact="$3"; version="$4"; classifier="${5:-}"; \
      dest=$(ls -1 "$LIB"/${prefix}-*.jar 2>/dev/null | head -n1 || true); \
      if [ -z "$dest" ]; then echo "skip $prefix (not present)"; return 0; fi; \
      if [ -n "$classifier" ]; then \
        url="https://repo1.maven.org/maven2/${group_path}/${artifact}/${version}/${artifact}-${version}-${classifier}.jar"; \
      else \
        url="https://repo1.maven.org/maven2/${group_path}/${artifact}/${version}/${artifact}-${version}.jar"; \
      fi; \
      echo "overlay $dest <- ${artifact}-${version}${classifier:+-${classifier}}"; \
      curl -fsSL -o "$dest" "$url"; \
    }; \
    overlay io.netty.netty-codec io/netty netty-codec 4.1.138.Final; \
    overlay io.netty.netty-codec-dns io/netty netty-codec-dns 4.1.138.Final; \
    overlay io.netty.netty-codec-http io/netty netty-codec-http 4.1.138.Final; \
    overlay io.netty.netty-codec-http2 io/netty netty-codec-http2 4.1.138.Final; \
    overlay io.netty.netty-codec-haproxy io/netty netty-codec-haproxy 4.1.138.Final; \
    overlay io.netty.netty-handler io/netty netty-handler 4.1.138.Final; \
    overlay com.fasterxml.jackson.core.jackson-databind com/fasterxml/jackson/core jackson-databind 2.21.6; \
    overlay com.fasterxml.jackson.core.jackson-core com/fasterxml/jackson/core jackson-core 2.21.6; \
    overlay io.opentelemetry.opentelemetry-api io/opentelemetry opentelemetry-api 1.62.0; \
    overlay io.opentelemetry.opentelemetry-api-incubator io/opentelemetry opentelemetry-api-incubator 1.62.0-alpha; \
    overlay io.micrometer.micrometer-core io/micrometer micrometer-core 1.16.7; \
    overlay org.postgresql.postgresql org/postgresql postgresql 42.7.13; \
    overlay org.mariadb.jdbc.mariadb-java-client org/mariadb/jdbc mariadb-java-client 3.5.10; \
    overlay com.microsoft.sqlserver.mssql-jdbc com/microsoft/sqlserver mssql-jdbc 13.6.0.jre11

# Remove the admin CLI uber-jar (kcadm/kcreg): it bundles its own vulnerable
# jackson-databind and is not used by the server. Realm setup is done from the
# host via the configure script.
RUN rm -rf /mnt/rootfs/opt/keycloak/bin/client \
        /mnt/rootfs/opt/keycloak/bin/kcadm.sh /mnt/rootfs/opt/keycloak/bin/kcadm.bat \
        /mnt/rootfs/opt/keycloak/bin/kcreg.sh /mnt/rootfs/opt/keycloak/bin/kcreg.bat

# Final image: patched rootfs with the original Keycloak image settings
FROM scratch

COPY --from=os-patch /mnt/rootfs/ /

ENV PATH=/opt/keycloak/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=en_US.UTF-8 \
    KC_RUN_IN_CONTAINER=true

ENV KC_DB=mysql
ENV KC_HTTP_RELATIVE_PATH=/auth

COPY ./themes/ /opt/keycloak/themes/

USER 1000
EXPOSE 8080 8443 9000

ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start"]
