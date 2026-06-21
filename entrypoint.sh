#!/bin/sh

# 1. Check for standard HTTP_PROXY
TARGET_PROXY="${HTTP_PROXY:-$http_proxy}"

if [ -z "$TARGET_PROXY" ]; then
  echo "No HTTP_PROXY provided. Starting directly."
  exec bun run server.prod.mjs
fi

echo "HTTP_PROXY detected: $TARGET_PROXY"

# 2. Parse the URL (Expected format: protocol://host:port)
PROXY_PROTO=$(echo "$TARGET_PROXY" | awk -F:// '{print $1}')
PROXY_HOST_PORT=$(echo "$TARGET_PROXY" | awk -F:// '{print $2}')
PROXY_HOST=$(echo "$PROXY_HOST_PORT" | cut -d: -f1)
PROXY_PORT=$(echo "$PROXY_HOST_PORT" | cut -d: -f2)

if [ -z "$PROXY_PROTO" ] || [ -z "$PROXY_HOST" ] || [ -z "$PROXY_PORT" ]; then
  echo "Error: HTTP_PROXY must be in the format protocol://host:port"
  exit 1
fi

# 3. Resolve hostname to numeric IP
PROXY_IP=$(getent hosts "$PROXY_HOST" | awk '{ print $1 }' | head -n 1)
if [ -z "$PROXY_IP" ]; then
  PROXY_IP="$PROXY_HOST"
fi

echo "Routing traffic through $PROXY_PROTO proxy at $PROXY_IP:$PROXY_PORT"

# 4. Generate the proxychains config
cat <<EOF > /etc/proxychains/proxychains.conf
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
$PROXY_PROTO $PROXY_IP $PROXY_PORT
EOF

# 5. CRITICAL: Unset the variables so Bun doesn't try to double-proxy
unset HTTP_PROXY
unset http_proxy

# 6. Execute app wrapped in proxychains
exec proxychains4 -q bun run server.prod.mjs
