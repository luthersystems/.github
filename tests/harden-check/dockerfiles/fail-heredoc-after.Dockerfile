# Fail: a package step in a RUN heredoc after the kit, and a lowercase run.
FROM luthersystems/build-harden:v0.1.46@sha256:f3c02942cf086e8b976f0bf3e7a089bd29efdb34e788f0eaad64f38db76d4c05 AS harden
FROM alpine:3.22
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
RUN <<SCRIPT
apk add --no-cache curl
SCRIPT
