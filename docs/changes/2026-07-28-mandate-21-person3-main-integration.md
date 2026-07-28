# Mandate 21 Person 3 main integration

## Summary

Merged the latest production Chart mainline into
`feat/mandate21-runtime-drill` and preserved the stricter Person 3 runtime
acceptance path.

## Changes

- Kept the FIS wrapper's runtime AZ selection and RDS-primary-aware four-template
  contract.
- Added fail-closed checks requiring all four FIS stop alarms to exist and be
  `OK` before a live experiment.
- Added the measured 15-minute recovery window and persisted reconciliation
  output.
- Aligned k6 JSONL fields with the actual Go reconciler contract:
  `testRequestId`, `traceId`, `startedAt`, `completedAt`, `httpStatus`,
  `durationMs`, `orderId`, and `outcome`.
- Added `skipCrds: true` for Kubecost because Cluster Controller/Turndown is
  disabled and the least-privilege AppProject intentionally cannot create CRDs.
- Kept the Accounting PreSync Job database-only with a five-minute deadline.
  A migration image that tries to initialize Kafka is stale and must fail
  closed rather than run a second Accounting consumer as a hook.

## Production evidence at diagnosis

- Kubecost sync failed because `turndownschedules.kubecost.com` was not
  permitted by AppProject `techx-corp`.
- Accounting migration Job used digest
  `sha256:2120bd0c4244f9768042fae69093c28c33f515baa7c4b181291db55fbb6cc7bd`
  and entered the regular Kafka consumer path despite `--migrate-only`.
- Supplying the full application environment made the hook remain Running and
  emit MSK TLS errors; it did not complete the migration.

## Remaining external gate

Person 2 must publish and promote an Accounting image built from Platform main
that exits after `DatabaseMigrator.RunMigration` when invoked with
`--migrate-only`. Live FIS remains prohibited until the PreSync Job completes,
Argo is `Synced/Healthy`, the durability/audit alarms are `OK`, and the
30-minute application gate passes.
