# Fixture for the harden-check test (the positive control): a step after the
# kit removes USERTrust RSA from the system bundle. Today's Sectigo chains end
# at that root, so the check must fail: the store lost a CA the policy keeps.
# The kit (v0.1.46) has no ca-keep.list, so this also tests the action's own
# copy of the list.
FROM luthersystems/build-harden:v0.1.46@sha256:f3c02942cf086e8b976f0bf3e7a089bd29efdb34e788f0eaad64f38db76d4c05 AS harden

FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
RUN rm /usr/share/ca-certificates/mozilla/USERTrust_RSA_Certification_Authority.crt && update-ca-certificates --fresh
