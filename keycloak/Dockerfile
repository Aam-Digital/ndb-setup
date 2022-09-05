# Inspired by https://www.keycloak.org/server/containers
FROM quay.io/keycloak/keycloak:19.0.1 as builder
ARG KC_DB=postgres
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:19.0.1
COPY --from=builder /opt/keycloak/lib/quarkus/ /opt/keycloak/lib/quarkus/
