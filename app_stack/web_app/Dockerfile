# ==============================================================================
# Dockerfile: Production Node.js Web Application
# Hardened non-root image for containerized deployment
# ==============================================================================

FROM node:20-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

# Final minimal runner stage
FROM node:20-alpine

LABEL maintainer="ServerAdmin DevOps Lab"
LABEL description="Containerized Web Application with Least-Privilege Execution"

ENV NODE_ENV=production
ENV PORT=3000

WORKDIR /app

# Copy runtime node_modules and code
COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./
COPY src/ ./src/

# Security Hardening: drop root privileges
USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:3000/health || exit 1

CMD ["node", "src/server.js"]

