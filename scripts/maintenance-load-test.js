import http from "k6/http";
import { check, fail, sleep } from "k6";
import { Rate } from "k6/metrics";

const browseSuccess = new Rate("browse_success");
const cartSuccess = new Rate("cart_success");
const checkoutSuccess = new Rate("checkout_success");

const rawBaseUrl = __ENV.BASE_URL || "";
if (!rawBaseUrl) {
  fail("BASE_URL is required. Use the public storefront URL, for example: BASE_URL=https://store.example.com k6 run scripts/maintenance-load-test.js");
}

const baseUrl = rawBaseUrl.replace(/\/$/, "");
if (baseUrl.includes("internal-") || baseUrl.includes("localhost") || baseUrl.includes("127.0.0.1")) {
  fail("Directive #3 must be validated from outside the cluster through the public storefront, not an internal ALB or port-forward.");
}

export const options = {
  scenarios: {
    money_flow: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.RATE || 2),
      timeUnit: "1s",
      duration: __ENV.DURATION || "15m",
      preAllocatedVUs: Number(__ENV.PRE_ALLOCATED_VUS || 10),
      maxVUs: Number(__ENV.MAX_VUS || 30),
      gracefulStop: "30s",
    },
  },
  thresholds: {
    browse_success: ["rate>=0.995"],
    cart_success: ["rate>=0.995"],
    checkout_success: ["rate>=0.99"],
    "http_req_duration{flow:browse}": ["p(95)<1000"],
    dropped_iterations: ["count==0"],
  },
  noConnectionReuse: false,
  userAgent: "techx-directive-03-maintenance-validation/1.0",
};

const headers = { "Content-Type": "application/json" };
const fallbackProductId = __ENV.PRODUCT_ID || "OLJCESPC7Z";

function extractProductId(response) {
  try {
    const body = response.json();
    const products = Array.isArray(body) ? body : body.products;
    return products && products.length > 0 && products[0].id
      ? products[0].id
      : fallbackProductId;
  } catch (_) {
    return fallbackProductId;
  }
}

export default function () {
  const userId = `directive-03-${__VU}-${__ITER}-${Date.now()}`;

  const homepage = http.get(`${baseUrl}/`, { tags: { flow: "browse" } });
  const products = http.get(`${baseUrl}/api/products`, { tags: { flow: "browse" } });
  const browseOk = check(homepage, { "homepage HTTP 200": (r) => r.status === 200 })
    && check(products, { "products HTTP 200": (r) => r.status === 200 });
  browseSuccess.add(browseOk);

  const productId = extractProductId(products);
  const cart = http.post(
    `${baseUrl}/api/cart`,
    JSON.stringify({
      userId,
      item: { productId, quantity: 1 },
    }),
    { headers, tags: { flow: "cart" } },
  );
  const cartOk = check(cart, { "cart HTTP 200": (r) => r.status === 200 });
  cartSuccess.add(cartOk);

  const checkout = http.post(
    `${baseUrl}/api/checkout`,
    JSON.stringify({
      userId,
      email: "directive-03@example.com",
      address: {
        streetAddress: "1600 Amphitheatre Parkway",
        city: "Mountain View",
        state: "CA",
        country: "United States",
        zipCode: "94043",
      },
      userCurrency: "USD",
      creditCard: {
        creditCardNumber: "4432-8015-6152-0454",
        creditCardCvv: 672,
        creditCardExpirationYear: 2030,
        creditCardExpirationMonth: 1,
      },
    }),
    { headers, tags: { flow: "checkout" } },
  );
  const checkoutOk = check(checkout, {
    "checkout HTTP 200 with order": (r) => r.status === 200 && r.body.includes("orderId"),
  });
  checkoutSuccess.add(checkoutOk);

  sleep(Number(__ENV.SLEEP || 0.2));
}
