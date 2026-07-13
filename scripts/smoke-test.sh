#!/usr/bin/env bash

# Smoke test script for techx-corp release
# Checks homepage, product list, add-to-cart, checkout, and optional edge path blocking
# (CloudFront; pass -a with the public HTTPS hostname, not the internal ALB).

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0;0m' # No Color

NAMESPACE="techx-corp-prod"
ALB_HOST=""
HOST=""
PORT_FORWARD_PID=""
FREE_PORT=""

function print_usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -n, --namespace <ns>    Kubernetes namespace (default: techx-corp-prod)"
  echo "  -h, --host <url>        Direct target host (skips port-forward, e.g. http://localhost:8080)"
  echo "  -a, --alb-host <url>    Public edge host for route-blocking checks (CloudFront alias or https://dxxx.cloudfront.net)"
  echo "  --help                  Show this help message"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -h|--host)
      HOST="$2"
      shift 2
      ;;
    -a|--alb-host)
      ALB_HOST="$2"
      shift 2
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"
      print_usage
      exit 1
      ;;
  esac
done

# Cleanup function to kill port-forwarding on exit
function cleanup() {
  if [ -n "$PORT_FORWARD_PID" ]; then
    echo -e "${BLUE}Stopping kubectl port-forward (PID: $PORT_FORWARD_PID)...${NC}"
    kill "$PORT_FORWARD_PID" || true
  fi
}
trap cleanup EXIT

# Setup target host
if [ -z "$HOST" ]; then
  # Find a free port on localhost
  echo -e "${BLUE}Finding free port on localhost...${NC}"
  for port in {28080..28090}; do
    if ! (echo >/dev/tcp/127.0.0.1/$port) &>/dev/null; then
      FREE_PORT=$port
      break
    fi
  done

  if [ -z "$FREE_PORT" ]; then
    echo -e "${RED}Could not find a free port in range 28080-28090${NC}"
    exit 1
  fi

  echo -e "${BLUE}Starting port-forward to service/frontend-proxy in namespace ${NAMESPACE} on port ${FREE_PORT}...${NC}"
  kubectl port-forward -n "$NAMESPACE" svc/frontend-proxy "$FREE_PORT":8080 >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!

  # Wait for port forward to become ready
  echo -e "${BLUE}Waiting for port-forward to establish...${NC}"
  RETRIES=10
  while [ $RETRIES -gt 0 ]; do
    if (echo >/dev/tcp/127.0.0.1/"$FREE_PORT") &>/dev/null; then
      echo -e "${GREEN}Port-forward ready on port ${FREE_PORT}!${NC}"
      break
    fi
    sleep 1
    RETRIES=$((RETRIES - 1))
  done

  if [ $RETRIES -eq 0 ]; then
    echo -e "${RED}Failed to establish port-forward to svc/frontend-proxy on port ${FREE_PORT}${NC}"
    exit 1
  fi

  HOST="http://localhost:$FREE_PORT"
else
  # Clean trailing slash from provided host
  HOST="${HOST%/}"
fi

echo -e "${BLUE}Smoke test targeting: $HOST${NC}"

# Test 1: Homepage GET
echo -e "${YELLOW}[Test 1/4] Checking Storefront Homepage...${NC}"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$HOST/")
if [ "$HTTP_STATUS" -eq 200 ]; then
  echo -e "${GREEN}✔ Storefront Homepage is UP (HTTP 200)${NC}"
else
  echo -e "${RED}✘ Storefront Homepage check failed with status $HTTP_STATUS${NC}"
  exit 1
fi

# Test 2: Product List GET
echo -e "${YELLOW}[Test 2/4] Fetching Product List...${NC}"
PRODUCT_RESPONSE=$(curl -s -w "\n%{http_code}" "$HOST/api/products")
HTTP_STATUS=$(echo "$PRODUCT_RESPONSE" | tail -n1)
PRODUCTS_JSON=$(echo "$PRODUCT_RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" -eq 200 ] && [ -n "$PRODUCTS_JSON" ]; then
  # Try to extract a product ID from JSON
  PRODUCT_ID=$(echo "$PRODUCTS_JSON" | grep -o '"id":"[^"]*"' | head -n1 | sed 's/"id":"//;s/"//g' || true)
  if [ -z "$PRODUCT_ID" ]; then
    PRODUCT_ID="OLJCESPC7Z"
    echo -e "${YELLOW}Could not parse product ID from API; using default fallback: $PRODUCT_ID${NC}"
  else
    echo -e "${GREEN}✔ Successfully fetched products. Selected Product ID: $PRODUCT_ID${NC}"
  fi
else
  echo -e "${RED}✘ Failed to retrieve product list (HTTP $HTTP_STATUS)${NC}"
  exit 1
fi

# Test 3: Add-to-cart POST
echo -e "${YELLOW}[Test 3/4] Testing Add to Cart...${NC}"
USER_ID="smoke-test-user-$(date +%s)"
CART_BODY=$(cat <<EOF
{
  "userId": "$USER_ID",
  "item": {
    "productId": "$PRODUCT_ID",
    "quantity": 2
  }
}
EOF
)

CART_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "$CART_BODY" -w "\n%{http_code}" "$HOST/api/cart")
HTTP_STATUS=$(echo "$CART_RESPONSE" | tail -n1)

if [ "$HTTP_STATUS" -eq 200 ]; then
  echo -e "${GREEN}✔ Successfully added items to cart for user $USER_ID (HTTP 200)${NC}"
else
  echo -e "${RED}✘ Add to cart failed (HTTP $HTTP_STATUS)${NC}"
  exit 1
fi

# Test 4: Checkout Flow POST
echo -e "${YELLOW}[Test 4/4] Testing Checkout Flow...${NC}"
CHECKOUT_BODY=$(cat <<EOF
{
  "userId": "$USER_ID",
  "email": "smoke-test@example.com",
  "address": {
    "streetAddress": "1600 Amphitheatre Parkway",
    "city": "Mountain View",
    "state": "CA",
    "country": "United States",
    "zipCode": "94043"
  },
  "userCurrency": "USD",
  "creditCard": {
    "creditCardNumber": "4432-8015-6152-0454",
    "creditCardCvv": 672,
    "creditCardExpirationYear": 2030,
    "creditCardExpirationMonth": 1
  }
}
EOF
)

CHECKOUT_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "$CHECKOUT_BODY" -w "\n%{http_code}" "$HOST/api/checkout")
HTTP_STATUS=$(echo "$CHECKOUT_RESPONSE" | tail -n1)
CHECKOUT_JSON=$(echo "$CHECKOUT_RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" -eq 200 ] && [[ "$CHECKOUT_JSON" == *"orderId"* ]]; then
  ORDER_ID=$(echo "$CHECKOUT_JSON" | grep -o '"orderId":"[^"]*"' | head -n1 | sed 's/"orderId":"//;s/"//g' || true)
  echo -e "${GREEN}✔ Checkout completed successfully! Order ID: $ORDER_ID (HTTP 200)${NC}"
else
  echo -e "${RED}✘ Checkout flow failed (HTTP $HTTP_STATUS). Response: $CHECKOUT_JSON${NC}"
  exit 1
fi

# Optional edge (CloudFront) route-blocking check — not the internal ALB
if [ -n "$ALB_HOST" ]; then
  ALB_HOST="${ALB_HOST%/}"
  if [[ ! "$ALB_HOST" =~ ^http ]]; then
    ALB_HOST="https://$ALB_HOST"
  fi

  echo -e "${YELLOW}[Edge Check] Testing CloudFront path-blocking at $ALB_HOST...${NC}"
  BLOCKED_PREFIXES=("/grafana" "/jaeger" "/loadgen" "/feature" "/flagservice" "/otlp-http")
  ALL_BLOCKED=true

  for prefix in "${BLOCKED_PREFIXES[@]}"; do
    ALB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ALB_HOST$prefix" || echo "000")
    if [ "$ALB_STATUS" -eq 403 ]; then
      echo -e "${GREEN}✔ Route $prefix is blocked (HTTP 403)${NC}"
    else
      echo -e "${RED}✘ Route $prefix is NOT blocked (HTTP $ALB_STATUS, expected 403)${NC}"
      ALL_BLOCKED=false
    fi
  done

  if [ "$ALL_BLOCKED" = false ]; then
    echo -e "${RED}✘ Edge route-blocking validation failed!${NC}"
    exit 1
  else
    echo -e "${GREEN}✔ All blocked routes successfully verified at the edge.${NC}"
  fi
fi

echo -e "\n${GREEN}★★ ALL SMOKE TESTS PASSED SUCCESSFULY ★★${NC}"
exit 0
