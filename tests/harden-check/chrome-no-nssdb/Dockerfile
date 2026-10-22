# Fixture for the harden-check test (buildenv#165, problem 2): a chromedp
# headless-shell binary (a hyphen, not an underscore) and no NSS database.
# Chrome then trusts its built-in roots, so the check must find the binary
# and fail.
FROM luthersystems/build-harden:v0.1.46@sha256:f3c02942cf086e8b976f0bf3e7a089bd29efdb34e788f0eaad64f38db76d4c05 AS harden

FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* && \
    mkdir -p /opt/headless-shell && printf '#!/bin/sh\n' >/opt/headless-shell/headless-shell && chmod +x /opt/headless-shell/headless-shell
RUN --mount=type=bind,from=harden,source=/harden,target=/harden sh /harden/harden.sh
