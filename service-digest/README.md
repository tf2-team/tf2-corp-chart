# Service digest overlays

Per-service immutable image digests written by the **techx-corp-platform**
publish workflow after `release-ready`.

## Layout

```text
service-digest/values-<service>.yaml
```

Example (`service-digest/values-checkout.yaml` after promote):

```yaml
# Managed by tf2-corp-platform secure delivery pipeline.
components:
  checkout:
    imageOverride:
      digest: "sha256:…"
```

Special cases:

| Service | Overlay shape |
|---|---|
| Most components | `components.<name>.imageOverride.digest` |
| `load-generator` | same digest for `load-generator` and `load-generator-worker` |
| `flagd-ui` | `components.flagd.sidecarImageDigests.flagd-ui` (does not replace sidecarContainers) |
| `mem0` | `mem0.image.digest` |

## Helm / Argo

Argo CD Applications for dev and prod list every `service-digest/values-*.yaml`
after the env overlay. Until a digest is present, templates keep using
`default.image.tag` (or existing image overrides).

Do not hand-edit digests for routine deploys — promote via platform CI after
image rebuild, scan, and attestation.

<!-- Change trail: @hungxqt - 2026-07-20 - Document service-digest overlay contract for selective image promote. -->
