# Change: Deploy customized OpenSearch from ECR

## Status

**Superseded** by `docs/changes/2026-07-10-opensearch-first-party-component.md`.

The custom ECR OpenSearch image remains, but it is no longer configured via a Helm subchart `opensearch.image` block. It is pulled as  
`{{ default.image.repository }}/opensearch:{{ default.image.tag }}`  
from the first-party `components.opensearch` workload.
