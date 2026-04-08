# GitOps Lifecycle

Axiome uses **GitHub Flow** as the branching strategy combined with **GitHub Actions** for CI/CD and **GitHub Environments** with protection rules for deployment governance. All infrastructure and application changes follow the same lifecycle: code review, automated validation, and controlled promotion.

---

## Branching Strategy — GitHub Flow

```
main (protected)
  │
  ├── feature/AXI-830-terraform-model     ← feature branches
  ├── fix/AXI-845-db-connection
  └── infra/add-monitoring-dashboard
```

- `main` is the single source of truth and is always deployable
- All work happens in short-lived feature branches
- Branches are merged to `main` via pull request only
- No long-lived branches (no `develop`, no `release/*`)

---

## Complete Lifecycle

### Phase 1 — Develop

```
Developer                         Local Stack
    │                                 │
    ├── git checkout -b feature/xxx   │
    ├── make changes                  │
    ├── make local-up  ──────────────►│ docker-compose
    ├── test locally   ◄──────────────│ localhost:3000/5173/8000
    └── git push origin feature/xxx   │
```

### Phase 2 — Review

```
GitHub                                    CI Checks
    │                                         │
    ├── Pull Request created                  │
    ├── Branch protection enforced            │
    │   ├── Require approvals (1+)            │
    │   ├── Require status checks ───────────►│
    │   │                                     ├── terraform fmt -check
    │   │                                     ├── terraform validate
    │   │                                     ├── terraform plan
    │   │                                     ├── secrets-check
    │   │                                     ├── test-backend
    │   │                                     ├── test-biocompute
    │   │                                     └── test-frontend
    │   ├── Require conversation resolution   │
    │   └── Require up-to-date branch         │
    └── PR approved and merged                │
```

### Phase 3 — Build & Deploy to Dev

Triggered automatically on merge to `main`:

```
CI Pipeline (ci.yml)
    │
    ├── 1. Test (parallel)
    │   ├── npm test (backend)
    │   ├── pytest (biocompute)
    │   └── npm test + tsc (frontend)
    │
    ├── 2. Build
    │   ├── docker build backend → tag with git SHA
    │   ├── docker build biocompute → tag with git SHA
    │   └── npm run build (frontend)
    │
    ├── 3. Push
    │   ├── docker push backend:<sha> + :latest
    │   ├── docker push biocompute:<sha> + :latest
    │   └── s3 sync frontend → axiome-dev-frontend
    │
    ├── 4. Deploy to dev
    │   ├── update backend container → image:<sha>
    │   └── update biocompute container → image:<sha>
    │
    └── 5. Health checks
        ├── GET /health → backend (200 OK)
        └── GET /health → biocompute (200 OK)
```

### Phase 4 — Promote to Staging

Manual trigger via GitHub Actions UI:

```
Operator                        Promote Pipeline (promote.yml)
    │                                      │
    ├── Go to Actions → Promote            │
    ├── Input: image_tag=<sha>             │
    ├── Input: target=staging              │
    ├── Input: run_migrations=true/false   │
    ├── Click "Run workflow" ─────────────►│
    │                                      ├── Validate image exists in registry
    │                                      ├── Run migrations (if enabled)
    │                                      ├── Deploy same SHA to staging
    │                                      └── Health checks
    │                                      │
    └── Verify staging ◄───────────────────┘
```

### Phase 5 — Promote to Production

Same workflow, different target:

```
Operator                        Promote Pipeline (promote.yml)
    │                                      │
    ├── Input: image_tag=<same-sha>        │
    ├── Input: target=production           │
    ├── Click "Run workflow" ─────────────►│
    │                                      ├── Validate image exists
    │                                      ├── Run migrations (if enabled)
    │                                      ├── Deploy same SHA to production
    │                                      └── Health checks
    │                                      │
    └── Verify production ◄────────────────┘
```

### Phase 6 — Infrastructure Changes

Infrastructure changes follow the same PR-based flow but use the Terraform pipeline:

```
PR with .tf changes              Terraform Pipeline (terraform.yml)
    │                                      │
    ├── Automatic plan on PR ─────────────►│
    │                                      ├── terraform init
    │                                      ├── terraform fmt -check
    │                                      ├── terraform validate
    │                                      └── terraform plan (comment on PR)
    │                                      │
    ├── PR approved and merged             │
    │                                      │
    ├── Manual apply ─────────────────────►│
    │   (workflow_dispatch)                ├── terraform init
    │                                      └── terraform apply -auto-approve
    │                                      │
    └── Verify infrastructure ◄────────────┘
```

---

## GitHub Repository Configuration

### Branch Protection Rules (main)

Configure at: Repository → Settings → Branches → Add rule for `main`

| Rule | Setting |
|------|---------|
| Require pull request before merging | Enabled |
| Required approvals | 1 (increase for production repos) |
| Dismiss stale reviews on new commits | Enabled |
| Require status checks to pass | Enabled |
| Required checks | `test-backend`, `test-biocompute`, `test-frontend`, `check-secrets` |
| Require branches to be up to date | Enabled |
| Require conversation resolution | Enabled |
| Restrict force pushes | Enabled (block all) |
| Restrict deletions | Enabled |

### GitHub Environments

Configure at: Repository → Settings → Environments

#### dev
- No protection rules (auto-deploy on merge)

#### staging
- Required reviewers: 1+ (team lead or operator)
- Wait timer: 0 minutes
- Deployment branches: `main` only

#### production
- Required reviewers: 2+ (founder + engineer)
- Wait timer: 5 minutes (cooling period)
- Deployment branches: `main` only

### Required Secrets per Environment

See [deployment.md](deployment.md) for the full list of required GitHub Actions secrets per environment.

---

## Rollback

```
Operator                        Promote Pipeline
    │                                  │
    ├── Identify last good SHA         │
    │   (git log, deployment history)  │
    │                                  │
    ├── Input: image_tag=<old-sha>     │
    ├── Input: target=<env>            │
    ├── Run workflow ─────────────────►│
    │                                  ├── Deploy previous version
    │                                  └── Health checks
    └── Verify rollback ◄─────────────┘
```

No rebuild needed — the old image is still in the registry.

---

## Audit Trail

Every change is traceable:

| What | Where |
|------|-------|
| Code changes | Git history, PR reviews |
| Infrastructure changes | Terraform plan/apply logs, PR reviews |
| Deployment events | GitHub Actions run logs |
| Who deployed what | GitHub Actions actor + workflow run metadata |
| Image versions | Container registry tags (git SHA) |
| Secret changes | GitHub Actions audit log |

---

## Complete Flow Summary

```
                    ┌──────────┐
                    │  Develop  │  feature branch + local stack
                    └─────┬────┘
                          │ git push
                    ┌─────▼────┐
                    │  Review   │  PR + CI checks + approval
                    └─────┬────┘
                          │ merge to main
                    ┌─────▼────┐
                    │  Build    │  test → build → push → deploy
                    └─────┬────┘
                          │ auto
                    ┌─────▼────┐
                    │   Dev    │  health checks → validate
                    └─────┬────┘
                          │ manual promote (same SHA)
                    ┌─────▼────┐
                    │ Staging   │  health checks → validate
                    └─────┬────┘
                          │ manual promote (same SHA)
                    ┌─────▼─────┐
                    │ Production │  health checks → monitor
                    └───────────┘
```

Every step is version-controlled, reviewed, and auditable. No manual changes to shared environments.
