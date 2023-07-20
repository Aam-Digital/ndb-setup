# Inspired by https://www.keycloak.org/server/containers
FROM quay.io/keycloak/keycloak:19.0.1 as builder
ARG KC_DB=postgres
RUN curl -L https://github.com/aerogear/keycloak-metrics-spi/releases/download/3.0.0/keycloak-metrics-spi-3.0.0.jar > /opt/keycloak/providers/keycloak-metrics-spi.jar
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:19.0.1
COPY --from=builder /opt/keycloak/lib/quarkus/ /opt/keycloak/lib/quarkus/
COPY --from=builder /opt/keycloak/providers/keycloak-metrics-spi.jar /opt/keycloak/providers/
