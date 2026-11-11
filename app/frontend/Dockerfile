# Stage 1: Build frontend assets (not part of final runtime image)
FROM node:26-alpine AS build

WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY index.html ./
COPY src/ ./src/
RUN npm run build

# Stage 2: minimal non-root runtime
FROM nginxinc/nginx-unprivileged:stable-alpine AS runtime

# Upgrade Alpine runtime libraries to patched repository versions.
# Keep Trivy HIGH/CRITICAL as the final release gate.
USER 0
RUN apk upgrade --no-cache

COPY --from=build /src/dist/ /usr/share/nginx/html/
USER 101:101
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
