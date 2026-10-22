# Fixture for the harden-check test: a Debian JDK links lib/security/cacerts
# and blocked.certs to files under /etc. The check must resolve both inside
# the image (not on the runner). The kit v0.1.45 does not edit a linked
# blocked.certs (luthersystems/buildenv#166), so today the check must fail
# here; with a fixed kit it must pass. The runner needs keytool for it, which the action
# installs when the check asks for it.
FROM luthersystems/build-harden:v0.1.45@sha256:ed783a0cd4faf6cd791b844970f00309cec76c4ab90b1e111d641ba44d67ba46 AS harden

FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates-java openjdk-17-jre-headless && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
