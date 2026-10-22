# A same-kit fixture shaped like connectorhub's Dockerfile-go: an earlier
# stage runs the kit, and the final stage is a hardened base image. The
# Dockerfile check (final stage only) cannot take it; same-kit checks only
# that it pins the kit checked.
FROM luthersystems/build-harden:v0.1.45@sha256:ed783a0cd4faf6cd791b844970f00309cec76c4ab90b1e111d641ba44d67ba46 AS harden

FROM alpine:3.22 AS local
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh

FROM luthersystems/service-base-alpine:v0.1.45 AS prod
