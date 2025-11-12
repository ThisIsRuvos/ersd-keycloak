FROM quay.io/keycloak/keycloak:26.0.2

ENV KC_DB=mysql
ENV KC_HTTP_RELATIVE_PATH=/auth

# COPY ./configure.sh /configure.sh
COPY ./themes/ /opt/keycloak/themes/
# COPY ./themes/ersd/ /opt/keycloak/themes/ersd
# COPY ./themes/ersd.2/ /opt/keycloak/themes/ersd.2

ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start"]
