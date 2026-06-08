#!/bin/sh
# Substitutes API_INTERNAL_FQDN into the nginx vhost at start, then
# hands off to nginx. The container app passes API_INTERNAL_FQDN as
# an env var (set by the platform-team Bicep).
set -eu

if [ -z "${API_INTERNAL_FQDN:-}" ]; then
    echo "FATAL: API_INTERNAL_FQDN env var is not set" >&2
    exit 1
fi

sed -i "s|__API_INTERNAL_FQDN__|${API_INTERNAL_FQDN}|g" /etc/nginx/conf.d/default.conf

exec nginx -g 'daemon off;'
