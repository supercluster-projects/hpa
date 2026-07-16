# Multi-stage customized Backstage Dockerfile (M3 Task M3.1.1)
# Stage 1: Build stage
FROM node:18-bookworm-slim AS build
WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 g++ make checkinstall libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy yarn and package locks
COPY package.json yarn.lock ./
COPY packages/app/package.json packages/app/package.json
COPY packages/backend/package.json packages/backend/package.json

# Install dependencies
RUN yarn install --frozen-lockfile --network-timeout 600000

# Copy codebase
COPY . .

# Install customized plugins
# Add ArgoCD, Argo Rollouts, and OIDC plugins
RUN yarn --cwd packages/app add @backstage/plugin-argocd @backstage/plugin-argo-rollouts @backstage/plugin-auth-backend
RUN yarn --cwd packages/backend add @backstage/plugin-auth-backend-module-oidc-provider

# Build the app
RUN yarn build --filter backstage-backend

# Stage 2: Production run stage
FROM node:18-bookworm-slim
WORKDIR /app

# Copy production bundle
COPY --from=build /app/packages/backend/dist/bundle.tar.gz .
RUN tar -xzf bundle.tar.gz && rm bundle.tar.gz

# Install production-only dependencies
RUN yarn install --production --frozen-lockfile

# Copy app-config for dynamic configuration
COPY app-config.yaml app-config.production.yaml ./

ENV PORT=7007
EXPOSE 7007

# Run as non-root container for production security hardening
USER node
CMD ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.production.yaml"]
