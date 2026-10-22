# A same-kit fixture shaped like connectorhub's Dockerfile-go: an earlier
# stage runs the kit, and the final stage is a hardened base image. The
# Dockerfile check (final stage only) cannot take it; same-kit checks only
# that it pins the kit checked.
FROM luthersystems/build-harden:v0.1.46@sha256:f3c02942cf086e8b976f0bf3e7a089bd29efdb34e788f0eaad64f38db76d4c05 AS harden

FROM alpine:3.22 AS local
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh

FROM luthersystems/service-base-alpine:v0.1.46 AS prod
