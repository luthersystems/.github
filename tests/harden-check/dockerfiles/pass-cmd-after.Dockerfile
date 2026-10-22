# Pass: CMD and HEALTHCHECK that name curl and npm run in the container, not
# in the build, and the kit stage's AS is on a continued line.
FROM luthersystems/build-harden:v0.1.45@sha256:ed783a0cd4faf6cd791b844970f00309cec76c4ab90b1e111d641ba44d67ba46 \
	AS harden
FROM node:22-alpine
RUN apk add --no-cache ca-certificates
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
HEALTHCHECK CMD curl -f http://localhost/
CMD ["npm", "start"]
