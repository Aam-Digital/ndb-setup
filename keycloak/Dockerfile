# Build repos that are not delpoyed (because these are feature branches)
FROM maven:3.9.4-eclipse-temurin-17 AS java
RUN git clone https://github.com/Aam-Digital/keycloak-2fa-email-authenticator.git email-auth
RUN cd email-auth && mvn package

# Inspired by https://www.keycloak.org/server/containers
FROM quay.io/keycloak/keycloak:22.0.1 AS builder
ARG KC_DB=postgres
ADD --chown=keycloak:keycloak https://github.com/aerogear/keycloak-metrics-spi/releases/download/3.0.0/keycloak-metrics-spi-3.0.0.jar /opt/keycloak/providers/keycloak-metrics-spi.jar
ADD --chown=keycloak:keycloak https://github.com/wouterh-dev/keycloak-spi-trusted-device/releases/download/v0.0.1-22/keycloak-spi-trusted-device-0.0.1-22.jar /opt/keycloak/providers/keycloak-trusted-device.jar
COPY --from=java email-auth/target/keycloak-2fa-email-authenticator-1.0.0.0-SNAPSHOT.jar /opt/keycloak/providers/keycloak-2fa-email-authenticator.jar
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:22.0.1
COPY --from=builder /opt/keycloak/lib/quarkus/ /opt/keycloak/lib/quarkus/
COPY --from=builder /opt/keycloak/providers /opt/keycloak/providers/
