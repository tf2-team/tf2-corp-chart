# Change: Align OpenSearch image contract in values-dev.yaml

## Status

**Superseded** by `docs/changes/2026-07-10-opensearch-first-party-component.md`.

OpenSearch is no longer a Helm subchart and no longer uses a separate `opensearch.image` block. It is a first-party `components.opensearch` workload that uses `default.image` only (same as other nested services).
