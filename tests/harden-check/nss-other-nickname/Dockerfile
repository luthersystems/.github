# Fixture for the harden-check test (buildenv#165, problem 1): the NSS
# database already holds a listed certificate, under a nickname of its own and
# with trust, before the kit runs. certutil does not rename a certificate a
# database holds, so the kit's harden-<name> nickname is never added for it.
# The check must find it by its fingerprint and pass, because its trust is
# p,p,p after the kit. A headless-shell binary is here too (problem 2), so the
# Chrome rule runs; with the NSS database it only warns.
FROM luthersystems/build-harden:v0.1.46@sha256:f3c02942cf086e8b976f0bf3e7a089bd29efdb34e788f0eaad64f38db76d4c05 AS harden

FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libnss3-tools && rm -rf /var/lib/apt/lists/*
COPY --from=harden /harden/policy/ca-distrust/comodo-aaa-certificate-services.pem /tmp/aaa.pem
RUN mkdir -p /root/.pki/nssdb && certutil -N -d sql:/root/.pki/nssdb --empty-password && \
    certutil -A -d sql:/root/.pki/nssdb -n "Old AAA name" -t C,C,C -i /tmp/aaa.pem && rm /tmp/aaa.pem && \
    mkdir -p /opt/headless-shell && printf '#!/bin/sh\n' >/opt/headless-shell/headless-shell && chmod +x /opt/headless-shell/headless-shell
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
