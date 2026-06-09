# aca-create-deploy-best-practice

A minimal, opinionated template for deploying **Azure Container Apps (ACA)** with **Bicep** in a way that lets you re-run infra deployments **without clobbering the image your app pipeline already pushed**.

---

## The problem this solves

Most teams start with one Bicep template that creates the ACA *and* sets the container image (usually `hello-world`). Then a separate pipeline pushes the real app image to ACR and runs `az containerapp update --image …`.

That works — until you re-run the Bicep template to add a queue, an env var, or a second app. Bicep's desired-state contract says: *"the image is `hello-world`"*, so it **flips every running app back to `hello-world`**. Production goes down.

Common workarounds all have problems:

| Workaround | Problem |
|---|---|
| Read existing ACA with `existing` | Throws `NotFound` on first deploy. Bicep has no try/catch. |
| `onlyIfDoesNotExist` flag | Makes the resource immutable from IaC — can't change env vars, scale, ingress. |
| Pre-deploy script captures state and feeds Bicep | ✅ **Correct pattern.** This repo. |
| "Poison" image on a different port | Pollutes revision history, breaks single-revision mode, confuses ops. |

## The fix: two pipelines, one source of truth

| Pipeline | Owns | Cadence | Tooling |
|---|---|---|---|
| **Infra** (Bicep) | ACA shape, env, ingress, scale, secrets, identity, ACR, KV | Weeks/months | `az deployment group create` with `image` as a **parameter** |
| **App** (CI/CD) | The container image only | Many/day | `az containerapp update --image <digest>` |

The infra pipeline **resolves the currently-deployed image before each Bicep run** (falling back to a bootstrap image on first deploy) and passes it in as a parameter. The app pipeline never touches Bicep.

---

## Quick start

Prereqs: Azure CLI, Bicep, an Azure subscription, a GitHub repo with OIDC federation to Azure (or set `AZURE_CREDENTIALS` secret).

```bash
# 1. Clone & set env
git clone https://github.com/simonjj/aca-create-deploy-best-practice
cd aca-create-deploy-best-practice
export RG=rg-aca-demo LOCATION=eastus2 APP=api

# 2. First-time infra deploy (bootstrap image = hello-world)
az group create -n $RG -l $LOCATION
./scripts/deploy-infra.sh

# 3. Build & deploy your real app
./scripts/deploy-app.sh

# 4. Re-run infra (e.g. change an env var) — image is preserved
./scripts/deploy-infra.sh
```

**PowerShell equivalent:**

```powershell
$env:RG = 'rg-aca-demo'; $env:LOCATION = 'eastus2'; $env:APP = 'api'
./scripts/deploy-infra.ps1
./scripts/deploy-app.ps1
./scripts/deploy-infra.ps1   # re-run; image is preserved
```

Check the running revision still points at your real image, not hello-world:

```bash
az containerapp show -g $RG -n $APP \
  --query "properties.template.containers[0].image" -o tsv
```

---

## Repo layout

```
.
├── README.md
├── infra/
│   ├── main.bicep                 # subscription/RG entry-point
│   ├── main.bicepparam            # default parameter values
│   └── modules/
│       ├── environment.bicep      # ACA env, Log Analytics, ACR, UAMI
│       └── containerapp.bicep     # one Container App; takes `image` as a param
├── src/
│   └── api/
│       ├── Dockerfile
│       └── app.py                 # tiny Flask app exposing /health and /
├── scripts/
│   ├── deploy-infra.sh            # bash: resolves current image, runs Bicep
│   ├── deploy-infra.ps1           # PowerShell equivalent
│   ├── deploy-app.sh              # bash: builds, pushes to ACR, updates revision
│   └── deploy-app.ps1             # PowerShell equivalent
└── .github/
    └── workflows/
        ├── infra-deploy.yml       # runs on changes to infra/**
        └── app-deploy.yml         # runs on changes to src/**
```

---

## How the image is preserved (the one trick)

`scripts/deploy-infra.sh`:

```bash
IMAGE=$(az containerapp show -g "$RG" -n "$APP" \
        --query "properties.template.containers[0].image" -o tsv 2>/dev/null \
        || echo "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest")

az deployment group create -g "$RG" \
   --template-file infra/main.bicep \
   --parameters image="$IMAGE" appName="$APP"
```

- On **first deploy**: `az containerapp show` returns 404 → we use the hello-world bootstrap.
- On **every subsequent deploy**: we read whatever image the app pipeline last pushed and feed it back in. Bicep stays declarative; infra changes don't touch the image.

`infra/modules/containerapp.bicep` treats `image` as a first-class parameter — never hard-coded.

---

## Conventions enforced by this template

- Container images are pinned **by digest** (`@sha256:...`) in production, not floating tags.
- Registry auth uses a **user-assigned managed identity** with `AcrPull` — no admin password, no secret rotation.
- Revision suffix = short git SHA → deterministic, diff-able revision names.
- `activeRevisionsMode: 'Single'` by default. Switch to `Multiple` if you want blue/green.
- Infra and app pipelines must **not run concurrently** for the same app (race on GET-mutate-PUT). Workflows below use `concurrency:` groups to enforce this.

---

## When *not* to use this template

- If you're using **Azure Developer CLI (`azd`)**, you already have this split for free — `azd provision` runs Bicep, `azd deploy` updates images. Use `azd` and skip this repo.
- If you have a single immutable image baked into Bicep on purpose (e.g. an internal-only worker that you only redeploy as a unit), the two-pipeline split is overkill.

---

## Bootstrap variants

If you can't put a shell script in front of `az deployment group create` (e.g. consumers run plain `az deployment group create` against your template directly), use the **bicep-only variant** in `infra/variants/bicep-only/` — it embeds the image lookup inside a `Microsoft.Resources/deploymentScripts` resource so a single Bicep deployment does the whole thing. See [`infra/variants/bicep-only/README.md`](infra/variants/bicep-only/README.md) for trade-offs.

---

## Further reading

- [ACA — DevOps pipeline best practices](https://learn.microsoft.com/azure/container-apps/devops-pipeline-best-practices)
- [ACA — Revisions](https://learn.microsoft.com/azure/container-apps/revisions)
- [ACA — Managed identity image pull](https://learn.microsoft.com/azure/container-apps/managed-identity-image-pull)
- [Bicep — `existing` keyword](https://learn.microsoft.com/azure/azure-resource-manager/bicep/existing-resource)
- Related upstream issues: [`microsoft/azure-container-apps#553`](https://github.com/microsoft/azure-container-apps/issues/553), [`#917`](https://github.com/microsoft/azure-container-apps/issues/917)

---

## License

MIT
