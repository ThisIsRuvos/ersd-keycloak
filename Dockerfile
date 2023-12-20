FROM jboss/keycloak:15.0.0

ARG path_ersd_theme
COPY $path_ersd_theme /opt/jboss/keycloak/themes/


