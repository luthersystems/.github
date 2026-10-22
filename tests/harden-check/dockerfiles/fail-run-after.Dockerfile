# Fail: a package step after the kit can restore a CA bundle.
FROM luthersystems/build-harden:v0.1.45@sha256:ed783a0cd4faf6cd791b844970f00309cec76c4ab90b1e111d641ba44d67ba46 AS harden
FROM alpine:3.22
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
RUN apk add --no-cache curl
