# Keycloak 26.7.0 remediates the Java CVEs flagged by AWS Inspector on the 26.4
# image (keycloak-services, netty, jackson-databind, mssql-jdbc, bouncycastle,
# postgresql, vertx). The OS-level findings (glibc, java-21-openjdk-headless,
# libcap, libtasn1, p11-kit-trust) are patched below with dnf, since Red Hat
# shipped those errata after the upstream image was built.
# Stage 1: upgrade RPMs inside the Keycloak rootfs using UBI9's dnf
# (the Keycloak image is ubi9-micro based and has no package manager)
FROM registry.access.redhat.com/ubi9:latest AS os-patch

COPY --from=quay.io/keycloak/keycloak:26.7.0 / /mnt/rootfs

RUN dnf -y upgrade --installroot /mnt/rootfs --releasever 9 \
        --setopt=install_weak_deps=0 --nodocs && \
    dnf clean all --installroot /mnt/rootfs && \
    rm -rf /mnt/rootfs/var/cache/dnf /mnt/rootfs/var/log/dnf* /mnt/rootfs/var/log/yum*

# Swap in patched jars for CVEs not yet fixed upstream in Keycloak 26.7.0:
# - jackson-databind 2.21.5 (CVE-2026-54512/54513/54518, PTV allow-list bypass)
# - opentelemetry-api 1.62.0 (CVE-2026-45292)
# The original filenames are kept because the Quarkus fast-jar classpath
# (lib/quarkus/quarkus-application.dat) references jars by exact path.
# Scanners read the version from the jar's embedded pom.properties.
RUN curl -fsSL -o /mnt/rootfs/opt/keycloak/lib/lib/main/com.fasterxml.jackson.core.jackson-databind-2.21.2.jar \
        https://repo1.maven.org/maven2/com/fasterxml/jackson/core/jackson-databind/2.21.5/jackson-databind-2.21.5.jar && \
    curl -fsSL -o /mnt/rootfs/opt/keycloak/lib/lib/main/io.opentelemetry.opentelemetry-api-1.57.0.jar \
        https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-api/1.62.0/opentelemetry-api-1.62.0.jar && \
    curl -fsSL -o /mnt/rootfs/opt/keycloak/lib/lib/main/io.opentelemetry.opentelemetry-api-incubator-1.57.0-alpha.jar \
        https://repo1.maven.org/maven2/io/opentelemetry/opentelemetry-api-incubator/1.62.0-alpha/opentelemetry-api-incubator-1.62.0-alpha.jar

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
