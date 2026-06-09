# bicep-only variant

A single `az deployment group create` deploys everything **and** preserves
the currently-deployed container image — no shell/PowerShell wrapper needed.

## Quick start

```bash
az group create -n rg-aca-demo -l eastus2
az deployment group create \
  -g rg-aca-demo \
  -f infra/variants/bicep-only/main.bicep \
  -p infra/variants/bicep-only/main.bicepparam
```

Re-run the same command after an app deployment — the image is preserved.

## How it works

`modules/current-image.bicep` is a `Microsoft.Resources/deploymentScripts`
resource that:

1. Creates a dedicated user-assigned managed identity.
2. Grants it `Reader` on the resource group.
3. Runs `az containerapp show` inside an Azure Container Instance to read
   `properties.template.containers[0].image`, retrying for ~60s to ride out
   RBAC propagation on the very first deploy.
4. Falls back to a bootstrap (`hello-world`) image when the app doesn't
   exist yet.
5. Emits the result as a module output, which `main.bicep` feeds into the
   Container App module's `image` parameter.

`forceUpdateTag = utcNow()` makes the lookup re-run on every deployment
instead of being cached by ARM.

## Trade-offs vs. the wrapper-script variant

| | wrapper script | bicep-only |
|---|---|---|
| One command? | No (script then `az deployment`) | ✅ Yes |
| Deploy time | Baseline | +30–60s (ACI cold start) |
| Extra resources | None | UAMI + role assignment + transient ACI + Storage Account for script |
| `what-if` shows the resolved image? | ✅ Yes | ❌ Only the script resource |
| First-deploy RBAC propagation | N/A | Handled by retry loop, but can still need a deploy retry |
| Permissions required | Identity that runs the wrapper | Identity that runs the deployment must be able to create UAMIs + role assignments at RG scope |

Recommendation: use the wrapper-script variant when you control the
pipeline; use bicep-only when the template is consumed by callers who only
do `az deployment group create`.
