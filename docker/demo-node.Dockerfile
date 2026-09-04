# Demo backend base image: node:20-slim (glibc — matches the host-built node_modules
# we bind-mount, so no reinstall) PLUS a system Chromium for Puppeteer-based features
# (screenshots / PDF export). Baking Chromium in means the stack needs the network
# only ONCE (this build); after that `make demo-up` runs fully offline. Chromium's own
# download is skipped by Puppeteer (PUPPETEER_SKIP_DOWNLOAD=true in compose); we point
# it at the Debian system binary at /usr/bin/chromium instead.
FROM node:20-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        chromium \
        fonts-liberation \
        ca-certificates \
        openssl \
    && rm -rf /var/lib/apt/lists/*

# Puppeteer looks here (set via PUPPETEER_EXECUTABLE_PATH in docker-compose.demo.yml).
ENV CHROME_BIN=/usr/bin/chromium

# Entrypoint that branches on INSPECT (see the script) — baked in so there is no
# fragile multi-line command in the compose file.
COPY docker/demo-backend-entrypoint.sh /usr/local/bin/demo-backend-entrypoint.sh
RUN chmod +x /usr/local/bin/demo-backend-entrypoint.sh
