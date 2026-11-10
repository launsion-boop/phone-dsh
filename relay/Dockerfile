# SPDX-License-Identifier: MIT
# PCLink v1 public relay (P28).
#
# Runtime image: Node 22 Alpine, only the pinned ws dependency.  The container
# is stateless: no volume, no writable root, no log file.  It listens on 8080
# and must sit behind a TLS-terminating reverse proxy for production wss.

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json relay.mjs ./
COPY src ./src
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "relay.mjs", "--host", "0.0.0.0", "--port", "8080"]
