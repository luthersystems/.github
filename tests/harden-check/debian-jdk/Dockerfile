# Fixture for the harden-check test: a Debian JDK links lib/security/cacerts
# and blocked.certs to files under /etc. The check must resolve both inside
# the image (not on the runner). Kits before v0.1.46 did not edit a linked
# blocked.certs (luthersystems/buildenv#166), so this image passes only with a
# fixed kit. The runner needs keytool for it, which the action installs when
# the check asks for it.
FROM luthersystems/build-harden:v0.1.46@sha256:f3c02942cf086e8b976f0bf3e7a089bd29efdb34e788f0eaad64f38db76d4c05 AS harden

FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates-java openjdk-17-jre-headless && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
