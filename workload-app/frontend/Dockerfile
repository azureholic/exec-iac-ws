# syntax=docker/dockerfile:1.7
# Build context is this folder (workload-app/frontend).

# ---------- build stage ----------
FROM mcr.microsoft.com/azurelinux/base/nodejs:24 AS build
WORKDIR /src

# Install deps first (better layer cache).
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json vite.config.ts index.html ./
COPY src ./src

RUN npm run build

# ---------- runtime stage ----------
FROM mcr.microsoft.com/azurelinux/base/nginx:1.28 AS runtime

# vhost template + main nginx.conf + entrypoint live next to the service so
# they stay editable and diff-able outside the Dockerfile. The main nginx.conf
# override is required because the Azure Linux nginx base image does NOT
# include /etc/nginx/conf.d/*.conf from its stock config.
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY nginx/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

COPY --from=build /src/dist /usr/share/nginx/html

EXPOSE 80
ENTRYPOINT ["/docker-entrypoint.sh"]
