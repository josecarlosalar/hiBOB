# ─── Etapa 1: Build ──────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci --ignore-scripts

COPY tsconfig*.json nest-cli.json ./
COPY src ./src

RUN npm run build

# Eliminar devDependencies para imagen final ligera
RUN npm prune --omit=dev

# ─── Etapa 2: Runtime ────────────────────────────────────────────────────────
FROM node:22-alpine AS runner

WORKDIR /app

# Usuario no-root por seguridad
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=builder --chown=appuser:appgroup /app/dist ./dist
COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appgroup /app/package.json ./package.json

USER appuser

# Cloud Run inyecta PORT automáticamente
ENV NODE_ENV=production
EXPOSE 8080

CMD ["node", "dist/main"]
