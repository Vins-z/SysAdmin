FROM nginx:1.25-alpine

LABEL maintainer="ServerAdmin DevOps Lab"
LABEL description="Production Hardened Nginx Reverse Proxy"

# Remove default configuration files
RUN rm -rf /etc/nginx/conf.d/*

# Copy custom configs
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80 443

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]

