# Change: Deliver the AI guardrail model from private S3

## Summary

The `product-reviews` pod now downloads a pinned prompt-injection model artifact
from its environment-specific private S3 bucket before the application starts.
This keeps model weights out of the application image while making startup
deterministic and fail-closed.

## Implementation

- Added a dedicated `product-reviews` ServiceAccount with an environment-specific
  IRSA role annotation.
- Added an AWS CLI init container that downloads `model.tar.gz` and its SHA-256
  file, verifies the checksum, extracts the Hugging Face cache into `emptyDir`,
  and requires a `.model-ready` marker.
- Mounted the cache read-only in the application and enabled Hugging Face and
  Transformers offline modes.
- Increased product-review CPU/memory for the local inference scanner.
- Added TCP 443 egress for the S3 bootstrap path. IRSA restricts the accessible
  bucket and prefix; the infrastructure S3 Gateway Endpoint keeps traffic on AWS.
- Added schema validation for `modelDelivery` and bumped the chart to `0.48.4`.

## Dependencies and Apply Order

1. Apply the matching `tf2-corp-infra` environment.
2. Build and upload all three artifacts to that environment bucket.
3. Verify the S3 URI and IRSA ARN against Terraform outputs.
4. Sync this chart.
5. Deploy the platform image that requires the external model.

Do not sync production after only uploading to development; the buckets are
separate. Full bootstrap and verification commands are in
`docs/operations/ai-model-delivery.md`.

## Validation

| Check | Status |
|---|---|
| YAML and JSON schema parsing | Passed locally |
| Python product-review tests | 34 passed in platform repo |
| Helm 3.17.3 lint with development overlay | Passed locally |
| Helm 3.17.3 lint with production overlay | Passed locally |
| Dev/prod render contains init, strict mode and environment bucket | Passed locally |
| Live IRSA/S3 init and rollout | Required after infra apply and artifact upload |

## Risks and Rollback

- A missing artifact, checksum mismatch or IRSA error intentionally leaves the
  pod in init failure rather than running reduced guardrails.
- Standard NetworkPolicy cannot select an AWS S3 prefix list, so TCP 443 egress
  is network-wide; least-privilege access is enforced at IAM and bucket layers.
- Roll back the chart revision to restore the previous pod specification. Keep
  the S3 artifact until rollback verification is complete.
