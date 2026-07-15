# AI guardrail model delivery

The product-reviews image contains runtime libraries but not Hugging Face model
weights. Each pod downloads a pinned, checksum-verified cache artifact from a
private S3 bucket into an `emptyDir` before the application starts.

## One-time development bootstrap

1. Apply `tf2-corp-infra/environments/development`. Record outputs
   `ai_model_bucket_name` and `ai_model_service_account_role_arn`.
2. In `tf2-corp-platform`, build the pinned artifact:

   ```powershell
   .\src\product-reviews\.venv\Scripts\python.exe `
     src\product-reviews\scripts\build_model_artifact.py
   ```

3. Upload all three immutable files:

   ```powershell
   $revision = "89b085cd330414d3e7d9dd787870f315957e1e9f"
   $prefix = "s3://techx-dev-tf2-ai-models-493499579600/protectai/deberta-v3-base-prompt-injection-v2/$revision"
   aws s3 cp dist/ai-model/model.tar.gz "$prefix/model.tar.gz"
   aws s3 cp dist/ai-model/model.tar.gz.sha256 "$prefix/model.tar.gz.sha256"
   aws s3 cp dist/ai-model/manifest.json "$prefix/manifest.json"
   ```

4. Merge/sync this chart only after the objects exist. The init container blocks
   startup on download, checksum, extraction, or marker validation failure.

## Verification

```powershell
kubectl -n techx-corp-dev rollout status deployment/product-reviews --timeout=10m
kubectl -n techx-corp-dev logs deployment/product-reviews -c fetch-ai-guardrail-model
kubectl -n techx-corp-dev get pod -l opentelemetry.io/name=product-reviews
```

Rollback the chart revision to restore the previous pod specification. Do not
overwrite an existing revision path; publish a new revision and update `s3Uri`.
