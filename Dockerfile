# Download JAR dependencies in a separate stage
FROM alpine:latest AS downloader

RUN apk add --no-cache wget

RUN mkdir -p /downloads && \
    wget -O /downloads/vertx-web-5.0.5.jar \
    https://repo1.maven.org/maven2/io/vertx/vertx-web/5.0.5/vertx-web-5.0.5.jar && \
    wget -O /downloads/vertx-web-common-5.0.5.jar \
    https://repo1.maven.org/maven2/io/vertx/vertx-web-common/5.0.5/vertx-web-common-5.0.5.jar && \
    wget -O /downloads/quarkus-jdbc-mssql-deployment-3.28.5.jar \
    https://repo1.maven.org/maven2/io/quarkus/quarkus-jdbc-mssql-deployment/3.28.5/quarkus-jdbc-mssql-deployment-3.28.5.jar

# Stage 2: Extract and modify quarkus-run.jar
FROM ubuntu:22.04 AS modifier

# Install unzip and zip tools
RUN apt-get update && apt-get install -y unzip zip && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy Keycloak files
COPY --from=quay.io/keycloak/keycloak:26.4 /opt/keycloak /opt/keycloak

# Copy downloaded JAR files
COPY --from=downloader /downloads/vertx-web-5.0.5.jar /opt/keycloak/lib/lib/main/io.vertx-web-5.0.5.jar
COPY --from=downloader /downloads/vertx-web-common-5.0.5.jar /opt/keycloak/lib/lib/main/io.vertx-web-common-5.0.5.jar
COPY --from=downloader /downloads/quarkus-jdbc-mssql-deployment-3.28.5.jar /opt/keycloak/lib/lib/deployment/io.quarkus.quarkus-jdbc-mssql-deployment-3.28.5.jar

# Update MANIFEST.MF in quarkus-run.jar
RUN mkdir -p /tmp/jar-extract && \
    cd /tmp/jar-extract && \
    unzip /opt/keycloak/lib/quarkus-run.jar && \
    sed -i 's|io\.vertx\.vertx-web-4\.5\.21\.jar|io.vertx-web-5.0.5.jar|g' META-INF/MANIFEST.MF && \
    sed -i 's|io\.vertx\.vertx-web-common-4\.5\.21\.jar|io.vertx-web-common-5.0.5.jar|g' META-INF/MANIFEST.MF && \
    sed -i 's|io\.quarkus\.quarkus-jdbc-mssql-deployment-3\.27\.0\.jar|io.quarkus.quarkus-jdbc-mssql-deployment-3.28.5.jar|g' META-INF/MANIFEST.MF && \
    zip -r /opt/keycloak/lib/quarkus-run.jar . && \
    cd / && rm -rf /tmp/jar-extract

# Final image
FROM quay.io/keycloak/keycloak:26.4

# Copy modified files from modifier stage
COPY --from=modifier /opt/keycloak/lib/lib/main/io.vertx-web-5.0.5.jar /opt/keycloak/lib/lib/main/io.vertx-web-5.0.5.jar
COPY --from=modifier /opt/keycloak/lib/lib/main/io.vertx-web-common-5.0.5.jar /opt/keycloak/lib/lib/main/io.vertx-web-common-5.0.5.jar
COPY --from=modifier /opt/keycloak/lib/lib/deployment/io.quarkus.quarkus-jdbc-mssql-deployment-3.28.5.jar /opt/keycloak/lib/lib/deployment/io.quarkus.quarkus-jdbc-mssql-deployment-3.28.5.jar
COPY --from=modifier /opt/keycloak/lib/quarkus-run.jar /opt/keycloak/lib/quarkus-run.jar

ENV KC_DB=mysql
ENV KC_HTTP_RELATIVE_PATH=/auth

COPY ./themes/ /opt/keycloak/themes/

ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start"]
