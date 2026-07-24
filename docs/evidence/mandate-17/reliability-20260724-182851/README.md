# Diagnostic run — not acceptance evidence

The baseline passed, but the first AZ attempt was invalid: the original harness
deleted Pods asynchronously and checked the fault boundary before termination
completed. The harness stopped, entered `finally`, and restored the cluster.
The k6 process continued successfully, but the five-minute acceptance window
never opened. Do not count this directory as an AZ-loss PASS.

This finding led to harness revision `0d85f98`, which waits up to a bounded
`EvacuationTimeoutSeconds` for zero Ready target Pods before opening the fault
window.
