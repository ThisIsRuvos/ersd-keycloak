# Keycloak 26.7.3 remediates CVE-2026-18963 (keycloak-services account takeover)
# and the 26.7.2/26.7.3 server CVEs. Inspector findings that remain on that
# base are closed here: UBI9 dnf for OS RPMs, and jar overlays for third-party
# libraries Keycloak has not bumped yet. Jackson stays on the 2.21 line
# (2.21.8); 2.22.3 is the other patched line and is not required.
# The 26.6.0 ORG_ID changeset has no precondition and fails when
# upgrading a 26.0.x MySQL schema that already has KEYCLOAK_GROUP.ORG_ID.
# Stage 1: upgrade RPMs inside the Keycloak rootfs using UBI9's dnf
# (the Keycloak image is ubi9-micro based and has no package manager)
FROM registry.access.redhat.com/ubi9:latest AS os-patch

COPY --from=quay.io/keycloak/keycloak:26.7.3 / /mnt/rootfs

RUN <<'EOS'
set -euo pipefail
dnf -y upgrade --installroot /mnt/rootfs --releasever 9 \
    --setopt=install_weak_deps=0 --nodocs
dnf -y install zip unzip python3
dnf clean all --installroot /mnt/rootfs
rm -rf /mnt/rootfs/var/cache/dnf /mnt/rootfs/var/log/dnf* /mnt/rootfs/var/log/yum*

# Fail the build if UBI has not yet published the errata Inspector lists.
ver_ge() {
  got="$1"
  want="$2"
  if [ "$got" = "$want" ]; then
    return 0
  fi
  low=$(printf '%s\n%s\n' "$got" "$want" | sort -V | head -n1)
  [ "$low" = "$want" ]
}
check_rpm() {
  name="$1"
  want="$2"
  got=$(rpm --root /mnt/rootfs -q --qf '%{VERSION}-%{RELEASE}' "$name")
  if ! ver_ge "$got" "$want"; then
    echo "$name is ${got}, need >= ${want}" >&2
    exit 1
  fi
  echo "os-patch $name ${got} >= ${want}"
}
check_rpm pcre2 10.40-7.el9_8
check_rpm pcre2-syntax 10.40-7.el9_8
check_rpm glibc 2.34-283.el9_8
check_rpm glibc-common 2.34-283.el9_8
check_rpm glibc-langpack-en 2.34-283.el9_8
check_rpm ca-certificates 2026.2.92_v9.0.319-90.3.el9_8
EOS

# Distrust the eMudhra roots (DSO-3028). ca-certificates 2026.2.92 drops them
# from the anchor bundle, but its %post cannot run inside UBI micro (trust has
# no libp11-kit), so the extracted Java store would stay stale. The builder
# regenerates that store from this image's anchors. If an older bundle still
# ships the roots, they are copied onto the blocklist first. Other emSign roots
# stay trusted.
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
blocklist_if_present() {
  filter="$1"
  out="$2"
  trust extract --overwrite --format=pem-bundle --filter="$filter" "$out"
  if grep -q 'BEGIN CERTIFICATE' "$out"; then
    echo "blocklisting $filter"
  else
    rm -f "$out"
    echo "already absent from anchors: $filter"
  fi
}
blocklist_if_present 'pkcs11:object=Comodo%20AAA%20Services%20root;type=cert' \
  "$blocklist/Comodo_AAA_Services_root.pem"
blocklist_if_present 'pkcs11:object=emSign%20ECC%20Root%20CA%20-%20G3;type=cert' \
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
      prefix="$1"; group_path="$2"; artifact="$3"; version="$4"; classifier="${5:-}"; pom_version="${6:-}"; \
      dest=$(ls -1 "$LIB"/${prefix}-[0-9]*.jar 2>/dev/null | head -n1 || true); \
      if [ -z "$dest" ]; then echo "skip $prefix (not present)"; return 0; fi; \
      if [ -n "$classifier" ]; then \
        url="https://repo1.maven.org/maven2/${group_path}/${artifact}/${version}/${artifact}-${version}-${classifier}.jar"; \
        expect="${pom_version:-${version}-${classifier}}"; \
      else \
        url="https://repo1.maven.org/maven2/${group_path}/${artifact}/${version}/${artifact}-${version}.jar"; \
        expect="${pom_version:-$version}"; \
      fi; \
      echo "overlay $dest <- ${artifact}-${expect}"; \
      curl -fsSL -o "$dest" "$url"; \
      props_path="META-INF/maven/${group_path}/${artifact}/pom.properties"; \
      if ! unzip -l "$dest" | grep -q " ${props_path}$"; then \
        staged=$(mktemp -d); \
        mkdir -p "${staged}/META-INF/maven/${group_path}/${artifact}"; \
        printf 'groupId=%s\nartifactId=%s\nversion=%s\n' "${group_path//\//.}" "$artifact" "$expect" \
          > "${staged}/${props_path}"; \
        (cd "$staged" && zip -q "$dest" "$props_path"); \
        rm -rf "$staged"; \
      fi; \
      got=$(unzip -p "$dest" "$props_path" | awk -F= '/^version=/{print $2; exit}'); \
      if [ "$got" != "$expect" ]; then \
        echo "expected ${expect} in ${dest}, found ${got:-missing}" >&2; \
        exit 1; \
      fi; \
    }; \
    overlay io.netty.netty-codec io/netty netty-codec 4.1.138.Final; \
    overlay io.netty.netty-codec-dns io/netty netty-codec-dns 4.1.138.Final; \
    overlay io.netty.netty-codec-http io/netty netty-codec-http 4.1.138.Final; \
    overlay io.netty.netty-codec-http2 io/netty netty-codec-http2 4.1.138.Final; \
    overlay io.netty.netty-codec-haproxy io/netty netty-codec-haproxy 4.1.138.Final; \
    overlay io.netty.netty-handler io/netty netty-handler 4.1.138.Final; \
    overlay com.fasterxml.jackson.core.jackson-databind com/fasterxml/jackson/core jackson-databind 2.21.8; \
    overlay com.fasterxml.jackson.core.jackson-core com/fasterxml/jackson/core jackson-core 2.21.8; \
    overlay com.fasterxml.jackson.dataformat.jackson-dataformat-cbor com/fasterxml/jackson/dataformat jackson-dataformat-cbor 2.21.8; \
    overlay com.fasterxml.jackson.dataformat.jackson-dataformat-yaml com/fasterxml/jackson/dataformat jackson-dataformat-yaml 2.21.8; \
    overlay com.fasterxml.jackson.datatype.jackson-datatype-jdk8 com/fasterxml/jackson/datatype jackson-datatype-jdk8 2.21.8; \
    overlay com.fasterxml.jackson.datatype.jackson-datatype-jsr310 com/fasterxml/jackson/datatype jackson-datatype-jsr310 2.21.8; \
    overlay com.fasterxml.jackson.jakarta.rs.jackson-jakarta-rs-base com/fasterxml/jackson/jakarta/rs jackson-jakarta-rs-base 2.21.8; \
    overlay com.fasterxml.jackson.jakarta.rs.jackson-jakarta-rs-yaml-provider com/fasterxml/jackson/jakarta/rs jackson-jakarta-rs-yaml-provider 2.21.8; \
    overlay com.fasterxml.jackson.module.jackson-module-jakarta-xmlbind-annotations com/fasterxml/jackson/module jackson-module-jakarta-xmlbind-annotations 2.21.8; \
    overlay com.fasterxml.jackson.module.jackson-module-parameter-names com/fasterxml/jackson/module jackson-module-parameter-names 2.21.8; \
    overlay org.freemarker.freemarker org/freemarker freemarker 2.3.35; \
    overlay org.bouncycastle.bcprov-jdk18on org/bouncycastle bcprov-jdk18on 1.85; \
    overlay org.bouncycastle.bcpkix-jdk18on org/bouncycastle bcpkix-jdk18on 1.85; \
    overlay org.bouncycastle.bcutil-jdk18on org/bouncycastle bcutil-jdk18on 1.85; \
    overlay com.google.guava.guava com/google/guava guava 33.7.2-jre; \
    overlay io.opentelemetry.opentelemetry-api io/opentelemetry opentelemetry-api 1.67.0; \
    overlay io.opentelemetry.opentelemetry-api-incubator io/opentelemetry opentelemetry-api-incubator 1.67.0-alpha; \
    overlay io.opentelemetry.opentelemetry-common io/opentelemetry opentelemetry-common 1.67.0; \
    overlay io.opentelemetry.opentelemetry-context io/opentelemetry opentelemetry-context 1.67.0; \
    overlay io.opentelemetry.opentelemetry-exporter-common io/opentelemetry opentelemetry-exporter-common 1.67.0; \
    overlay io.opentelemetry.opentelemetry-exporter-otlp io/opentelemetry opentelemetry-exporter-otlp 1.67.0; \
    overlay io.opentelemetry.opentelemetry-exporter-otlp-common io/opentelemetry opentelemetry-exporter-otlp-common 1.67.0; \
    overlay io.opentelemetry.opentelemetry-sdk io/opentelemetry opentelemetry-sdk 1.67.0; \
    overlay io.opentelemetry.opentelemetry-sdk-common io/opentelemetry opentelemetry-sdk-common 1.67.0; \
    overlay io.opentelemetry.opentelemetry-sdk-extension-autoconfigure io/opentelemetry opentelemetry-sdk-extension-autoconfigure 1.67.0; \
    overlay io.opentelemetry.opentelemetry-sdk-extension-autoconfigure-spi io/opentelemetry opentelemetry-sdk-extension-autoconfigure-spi 1.67.0; \
    overlay io.opentelemetry.opentelemetry-sdk-logs io/opentelemetry opentelemetry-sdk-logs 1.67.0; \
    overlay io.opentelemetry.opentelemetry-sdk-metrics io/opentelemetry opentelemetry-sdk-metrics 1.67.0; \
    overlay io.opentelemetry.opentelemetry-sdk-trace io/opentelemetry opentelemetry-sdk-trace 1.67.0; \
    overlay io.micrometer.micrometer-core io/micrometer micrometer-core 1.16.7; \
    overlay org.postgresql.postgresql org/postgresql postgresql 42.7.13; \
    overlay org.mariadb.jdbc.mariadb-java-client org/mariadb/jdbc mariadb-java-client 3.5.10; \
    overlay com.microsoft.sqlserver.mssql-jdbc com/microsoft/sqlserver mssql-jdbc 13.6.0.jre11 "" 13.6.0

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
