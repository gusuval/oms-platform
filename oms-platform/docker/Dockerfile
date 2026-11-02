# syntax=docker/dockerfile:1.6
# ── Dockerfile del OMS ────────────────────────────────────────────
# (La directiva `syntax` solo funciona si es la PRIMERA línea del fichero.)
#
# Multi-stage. Cumple la spec del Vídeo 1:
#   ✓ usuario no-root (UID > 10000)
#   ✓ HEALTHCHECK contra /healthz
#   ✓ Labels OCI con trazabilidad (revision/created inyectados en el build)
#   ✓ Tamaño minimizado (alpine runtime, solo dependencias de producción)
#   ✓ Cero secretos en capas (llegan en runtime desde Secret Manager)
#
# Build (contexto = app/):
#   docker build -f docker/Dockerfile \
#     --build-arg GIT_SHA=$(git rev-parse HEAD) \
#     --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
#     --build-arg VERSION=1.0.0 app/

ARG NODE_VERSION=22.11.0

# ─── Etapa 1: dependencias ────────────────────────────────────────
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app

# Aprovechar cache: solo se reinstala si cambian package*.json
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# ─── Etapa 2: runtime ─────────────────────────────────────────────
FROM node:${NODE_VERSION}-alpine
WORKDIR /app

# Usuario no-root con UID alto
RUN addgroup -g 10001 oms && \
    adduser  -u 10001 -G oms -s /bin/false -D oms

# node_modules de la etapa anterior + código. Los ficheros quedan de root:
# el proceso (UID 10001) puede leerlos pero no modificarlos.
COPY --from=deps /app/node_modules ./node_modules
COPY . .

USER 10001:10001

ENV NODE_ENV=production \
    PORT=8080

EXPOSE 8080

# Docker/Compose lo usan; Cloud Run lo ignora y usa sus startup/liveness
# probes (definidas en Terraform contra el mismo /healthz).
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ARG VERSION=0.0.0-dev
LABEL org.opencontainers.image.title="acme-oms" \
      org.opencontainers.image.description="AcmeOMS — monolito modular de gestión de pedidos" \
      org.opencontainers.image.vendor="AcmeOMS" \
      org.opencontainers.image.source="https://github.com/gusuval/oms-platform" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="MIT"

CMD ["node", "server.js"]
