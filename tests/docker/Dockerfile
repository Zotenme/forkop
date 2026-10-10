# Local test environment mirroring .github/workflows/backend-ci.yml and frontend-ci.yml.
FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git libjson-c-dev pkg-config ca-certificates curl shellcheck \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch v0.0.20250529 https://github.com/jow-/ucode.git /tmp/ucode \
 && cmake -S /tmp/ucode -B /tmp/ucode/build \
      -DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF -DULOOP_SUPPORT=OFF \
 && cmake --build /tmp/ucode/build --parallel \
 && cmake --install /tmp/ucode/build \
 && ldconfig \
 && rm -rf /tmp/ucode \
 && ucode -e 'print("ucode ready\n")'

RUN git config --system --add safe.directory '*'

WORKDIR /src
