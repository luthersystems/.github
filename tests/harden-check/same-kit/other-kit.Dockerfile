# A same-kit fixture that pins another kit than the one checked: it must fail.
FROM luthersystems/build-harden:v0.1.44@sha256:0000000000000000000000000000000000000000000000000000000000000000 AS harden

FROM alpine:3.22 AS local
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh

FROM luthersystems/service-base-alpine:v0.1.46 AS prod
