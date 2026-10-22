# harden-check

A composite action that proves, in CI, that an image holds the build-harden
policy of [luthersystems/buildenv](https://github.com/luthersystems/buildenv)
(`images/harden`): no listed CA (the emSign roots, the eMudhra intermediates
and Comodo AAA, which cross-signs them) is trusted anywhere in the image.

## Why it exists

The kit runs `harden.sh` inside each Dockerfile, at build time. A later
Dockerfile step, or a tool that brings its own root list, can undo it, so each
repo must also check the image it ships. Each repo used to carry its own copy
of the CI glue for that. This action is the one copy. It is released with this
repo's tags, so a fix to the check reaches every repo when `v1` moves, with no
kit release and no PR per repo.

## What stays where

| Part | Where | Why |
|---|---|---|
| Harden step (`harden.sh`) | The kit image, `luthersystems/build-harden`, run in each Dockerfile | An action cannot run inside `docker build`. |
| Policy (the listed certificates) | The kit image | The check reads the policy of the kit the caller pins, so it checks the same list that `harden.sh` applied. |
| Checks (`check/dockerfile.sh`, `check/image.sh`) and the CI glue | This action | One copy, one version for every repo. |

## Use

```yaml
- uses: luthersystems/.github/actions/harden-check@v1
  with:
    # Optional when the Dockerfiles pin the kit stage.
    kit: luthersystems/build-harden:v0.1.45@sha256:ed783a0cd4faf6cd791b844970f00309cec76c4ab90b1e111d641ba44d67ba46
    dockerfiles: Dockerfile
    images: |
      my-image:${{ github.sha }}
    platforms: linux/amd64 linux/arm64
```

| Input | Default | What it does |
|---|---|---|
| `kit` | read from the Dockerfiles | The kit image, pinned by digest. Set it for an image with no Dockerfile (ko) or one built on a hardened base image. A Dockerfile that pins another kit fails. |
| `dockerfiles` | none | Dockerfiles or directories to check: the kit must run last in the final stage. |
| `same-kit` | none | Files that must pin the kit checked but get no Dockerfile check, such as a Dockerfile whose final stage is a hardened base image while an earlier stage runs the kit. A file that pins another kit, or none, fails. This catches a kit bump that misses a file. |
| `images` | none | One image per line: `REF`, or `REF PLATFORM` for a tag that holds one platform (separate amd64 and arm64 tags). |
| `platforms` | the image's default | Platforms to check for each image line that names none. |
| `min-roots` | `100` | The fewest certificates the system bundle must hold. `0` allows an image with no TLS client. |
| `strict-binaries` | `false` | Fail, not only warn, on a binary or source file that holds a listed certificate. |
| `allow` | none | Image paths to skip, one glob per line. Say why beside the input. |
| `install-tools` | `true` | Install missing host tools with apt: keytool and certutil only when an image has a Java keystore or an NSS database. |

The Dockerfile check refuses a heredoc (`RUN <<EOF`, `COPY <<EOF`): a line
check cannot tell a heredoc's body from instructions, and a body line could
fake one. Use a script file or a plain `RUN` instead. It may fail a safe
Dockerfile; it must never pass an unsafe one.

Give `dockerfiles`, `images` or both. The image must be in the runner's docker
daemon (for example `docker buildx build --load`) or pullable. The check
exports the image's file system and runs every check on the host, so an image
of another architecture needs no emulation.

## Versions

Pin `@v1`. `v1` moves to each compatible release (`v1.MINOR.PATCH`); a change
that needs callers to change goes to `v2`. `release.yml` cuts the releases.

## Tests

`ci.yml` runs the action on both architectures: a hardened base image passes,
a plain Alpine image fails, and fixtures in `tests/harden-check` cover an NSS
database that holds a listed certificate under another nickname, and a
chromedp `headless-shell` binary (both from luthersystems/buildenv#165).
The `same-kit` fixtures cover a file that pins the kit checked (passes),
another kit and no kit (both fail).
