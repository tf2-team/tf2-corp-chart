# SEC-04: Security Context Hardening Notes

This document lists the components in the TechX Corp Platform Helm Chart that are configured with `readOnlyRootFilesystem: false` along with the technical justification for each exception.

## Documented Exceptions for `readOnlyRootFilesystem: false`

The following components require a writable root filesystem to run correctly, as their runtime storage, configuration, or temp paths are not yet fully isolated or require writing to standard system paths.

| Component | Image | Technical Reason for Exception |
|---|---|---|
| **postgresql** | `postgres:17.6` | Runs a stateful PostgreSQL database engine. Requires writing to data files, transaction logs, configuration, and temporary directories. |
| **kafka** | `confluentinc/cp-kafka` (or equivalent) | Runs a stateful Kafka broker. Persists topics, partition state, and cluster metadata to disk. |
| **valkey-cart** | `valkey/valkey:9.0.1-alpine3.23` | Valkey (Redis-compatible) cache and data store used to persist shopping cart state. Writes dump files (`.rdb`/`.aof`) and requires a writable workspace. |
| **opensearch** | `opensearchproject/opensearch:3.6.0` | Search and log analytics engine. Requires a writable root filesystem for runtime storage, logs, locking, and temporary java process directories. |

## Baseline Hardening Rules Applied

For all other components, the baseline security context is defined in `values.yaml` and enforced via Helm template merging:

1. **Pod Level (`podSecurityContext`):**
   - `seccompProfile.type: RuntimeDefault`
2. **Container Level (`securityContext`):**
   - `runAsNonRoot: true`
   - `allowPrivilegeEscalation: false`
   - `readOnlyRootFilesystem: true`
   - `capabilities.drop: ["ALL"]`
3. **Init Containers (`initContainerSecurityContext`):**
   - Inherits the container level baseline.
   - Configured with `runAsUser: 10001` and `runAsGroup: 10001` to ensure `busybox` based init containers do not run as root.
