# Infrastructure Graduation Criteria

This document defines the **observable signals** that indicate the infrastructure should graduate from one phase to the next, as defined in [architecture-evolution.md](architecture-evolution.md). The criteria are concrete, measurable, and tied to operational or business outcomes — not gut feel.

Use these criteria to make graduation decisions defensible (to engineering, to the business, to auditors). Tracking them quarterly is the recommended cadence.

---

## 1. Phase Graduation Decision Framework

A phase graduation is justified when **one or more of the following is true**:

- **Operational** — current architecture has experienced incidents that the next phase would have prevented
- **Business** — new contractual or product commitments cannot be honored at the current architecture
- **Capacity** — measured headroom on a load axis is below threshold
- **Compliance** — audits, customer demands, or regulation require capabilities not present at current phase

Signals are grouped into these four categories. **Three or more signals from any single category** is the recommended threshold for graduation. **One operational or compliance signal** can be sufficient in isolation if the impact is severe enough.

---

## 2. Phase 1 → Phase 2 (Production graduates to Fargate)

Triggers the move of *production only* from Lightsail to ECS Fargate behind an ALB. Dev and staging stay on Phase 1.

### 2.1. Operational signals

| Signal | How to measure | Threshold |
|---|---|---|
| Production downtime caused by single-VM outage | Incident log; uptime monitor reports | ≥1 incident per quarter, OR any incident exceeding RTO target |
| Failed deploys caused by 30s gap during `docker compose up` | Postmortem / customer complaint | ≥1 customer-impacting incident |
| OOM kills cascading across services | `dmesg` / docker events; alert from monitor | ≥2 events per month |
| CPU saturation on Lightsail VM at p95 | CloudWatch Lightsail metrics | >80% sustained for ≥1h, ≥3 times per quarter |
| Memory saturation at p95 | CloudWatch Lightsail metrics | >85% sustained for ≥1h, ≥3 times per quarter |
| Manual rebuild triggered (planned or unplanned) | Operations log | ≥2 per quarter |

### 2.2. Business signals

| Signal | How to measure | Threshold |
|---|---|---|
| Customer SLA promised (≥99.5% uptime) | Signed contract | Any single contract |
| Compliance certification required (SOC 2, ISO 27001, HIPAA) | Customer demand or audit scope | Any active requirement |
| Tenant count growth | Tenant table count | >20 tenants OR growth >50%/quarter |
| Regulated-industry customer onboarded | Sales pipeline | First customer in regulated vertical (life sciences, healthcare, finance) |
| Public launch / press announcement | Marketing calendar | Within 90 days |

### 2.3. Capacity signals

| Signal | How to measure | Threshold |
|---|---|---|
| Production peak request rate | ALB / Caddy access logs | >50 req/sec sustained |
| Production data volume — Postgres | Neon dashboard | >5 GB OR autosuspend disabled |
| Production data volume — Mongo | Atlas dashboard | M10+ tier required |
| Biocompute job queue depth | Application metric | >5 concurrent long-running jobs at peak |
| Active concurrent users at peak | Application metric | >100 |

### 2.4. Compliance signals

| Signal | How to measure | Threshold |
|---|---|---|
| Documented HA / failover procedure required | Audit checklist | Any active audit requirement |
| Multi-AZ deployment required | Customer contract or audit | Any single requirement |
| Per-tenant data residency required | Customer contract | Any active requirement |
| Backup restore drill required | Audit checklist | Any active requirement |
| WAF / DDoS protection required | Audit checklist or threat model | Any active requirement |

### 2.5. Decision threshold

Graduate production to Phase 2 if **any of the following is true**:

- ≥3 signals in any single category
- ≥1 operational signal (single-VM outage, failed deploy, cascading OOM)
- ≥1 compliance signal in active scope
- Customer SLA contractually committed at ≥99.5%

---

## 3. Phase 2 → Phase 3 (Production scales to multi-tenant load)

Triggers full production-grade architecture: autoscaling, CDN, WAF, sharding consideration, per-tenant observability.

### 3.1. Operational signals

| Signal | How to measure | Threshold |
|---|---|---|
| Fargate task count saturation | ECS service metrics | Reached `desired_count_max` ≥3 times per quarter |
| Database CPU saturation | Neon / Atlas dashboards | >70% sustained for ≥1h, ≥3 times per quarter |
| Cross-AZ data transfer cost | AWS bill | >€100/month |
| ALB connection errors | ALB metrics | >0.1% of requests per day |
| Noisy-neighbor incident reported | Tenant complaint or postmortem | ≥1 confirmed |

### 3.2. Business signals

| Signal | How to measure | Threshold |
|---|---|---|
| Customer SLA promised (≥99.9% uptime) | Signed contract | Any single contract |
| Tenant count | Tenant table | >100 tenants |
| Revenue threshold | Finance | Infrastructure cost <2% of MRR (suggests under-investment) |
| Geographic expansion | Customer geography | Customers in second region requiring latency <100ms |
| Per-tenant feature isolation required | Product roadmap | Active feature requiring per-tenant flagging |

### 3.3. Capacity signals

| Signal | How to measure | Threshold |
|---|---|---|
| Postgres data volume | Neon dashboard | >100 GB OR write throughput >1k/s sustained |
| Mongo data volume | Atlas dashboard | >100 GB OR sharding suggested by Atlas advisor |
| Peak concurrent users | Application metric | >1000 |
| Peak biocompute job throughput | Application metric | >50 concurrent long-running jobs |
| S3 egress | AWS bill | >€500/month — CloudFront cost-justified |

### 3.4. Compliance signals

| Signal | How to measure | Threshold |
|---|---|---|
| WAF required | Audit / threat model | Any active requirement |
| Per-tenant audit log required | Compliance scope | Any active requirement |
| Cross-region DR required | Audit / contract | Any active requirement |
| GDPR per-tenant deletion / export request | Customer request | First production request received |
| Penetration test scope expanded | Audit calendar | Any new scope requiring multi-AZ |

### 3.5. Decision threshold

Graduate production to Phase 3 if **any of the following is true**:

- ≥3 signals in any single category
- ≥1 capacity signal (DB volume, peak load) above threshold
- ≥1 compliance signal in active scope
- Customer SLA committed at ≥99.9%

---

## 4. Reverse-Direction Signals (Stay or Roll Back)

It is also valid to **not graduate**, even when signals are present, if the following hold. Document this when applicable.

| Reason to stay | How to validate |
|---|---|
| Cost increase not justified by signals | Compare phase-2 monthly cost vs. revenue / runway impact |
| Current incident frequency below tolerable threshold | <1 customer-impacting incident per quarter |
| Operational maturity not yet matched to next phase | Team has no on-call rotation, no runbooks, no observability discipline |
| Pilot still validating product-market fit | Tenant count <5, no contractual SLAs |
| Migration window not available | Active sales cycle, demo schedule, audit in flight |

A "stay at Phase 1" decision should be **revisited every quarter**, not deferred indefinitely. Stale graduation decisions become stale risk.

---

## 5. Required Observability to Make Graduation Decisions

The criteria above are useless without instrumentation. **From Phase 1 day one**, the following must be in place:

### 5.1. Uptime and availability

- External uptime monitor hitting `/health` from outside the VM (UptimeRobot, BetterStack, or AWS CloudWatch Synthetics) — **required**
- Quarterly uptime report per environment — **required for production**
- Incident log with cause, duration, customer impact — **required**

### 5.2. Resource utilization

- Lightsail CloudWatch metrics: CPU, memory, disk, network — **default in AWS**
- Per-container resource usage: `docker stats` snapshots or cAdvisor — **recommended**
- Neon dashboard: connection count, CPU, storage, query latency — **default in Neon**
- Atlas dashboard: ops/sec, queue depth, storage, replication lag — **default in Atlas**

### 5.3. Application telemetry

- Structured JSON logs with `tenant_id` field — **required from Phase 1**
- Log shipping to external store (CloudWatch Logs, BetterStack) — **required for production**
- Request latency histograms (p50, p95, p99) per service — **required**
- Error rate per service per tenant — **required**
- Biocompute job duration distribution — **required**

### 5.4. Cost telemetry

- AWS billing alerts at €50, €100, €200 thresholds — **required**
- Neon and Atlas usage tracked monthly — **required**
- Per-environment cost breakdown — **required for production**

### 5.5. Capacity headroom

- Tenant count tracked over time — **required**
- Postgres row count and DB size growth rate — **required**
- Mongo collection size growth rate — **required**
- S3 bucket size growth rate — **required**
- Concurrent user peak per day — **required**

If any of these are missing, **install them before considering graduation** — without them you cannot make a defensible graduation decision.

---

## 6. Decision Process

When graduation criteria are met:

1. **Document the signals.** Which thresholds were crossed, when, with what evidence (links to dashboards, incident reports, contracts).
2. **Estimate the cost of the next phase.** Concrete monthly figure with confidence interval.
3. **Estimate the migration effort.** Person-days, calendar window, risk of customer-visible disruption.
4. **Estimate the cost of NOT graduating.** SLA penalty, lost contract, compliance failure, reputation, opportunity cost.
5. **Stakeholder review.** Engineering + product + finance sign-off for production graduations. Engineering alone for dev/staging changes.
6. **Schedule the migration window.** Avoid sales demos, audits, customer onboarding sprints.
7. **Execute migration following [architecture-evolution.md §7](architecture-evolution.md#7-migration-map-phase-1--phase-2).**
8. **Postmortem after stabilization.** What worked, what didn't, what to improve before next graduation.

---

## 7. Anti-patterns

These are common reasons to graduate that are **not valid**:

- **"It feels too simple."** Lightsail-on-managed-DBs is a legitimate production architecture for the right scale. Aesthetic preference is not a graduation signal.
- **"Other companies use Fargate."** Industry mimicry without cause is over-investment.
- **"We might need it later."** Pre-emptive graduation costs real money against speculative future need. Wait for signals.
- **"The CTO/founder wants HA."** Translate this into an explicit signal (signed customer SLA, audit requirement). Otherwise it's an unscoped wish.
- **"We have budget."** Budget is a constraint, not a goal. Spend on signals, not capacity.
- **"It would be a good case study."** Marketing motivation is not architectural motivation.

Conversely, these are **valid** reasons to graduate even without signals crossing threshold:

- **Strategic timing window.** A quiet operational period coinciding with a forthcoming product launch may justify pre-emptive graduation if calendar slack is otherwise unavailable for a year.
- **Talent / hiring constraint.** If the team capable of doing the migration is leaving, graduating before they leave is sometimes correct.
- **Vendor change risk.** A managed-service provider is being acquired or sunsetting features — migrate ahead of the forced change.

These exceptions should be documented and dated, not invoked routinely.

---

## 8. Quarterly Review Template

Run this checklist every quarter for production:

```
[ ] Pull metrics from monitoring for the past 90 days
[ ] Count incidents and downtime minutes
[ ] Check tenant count and growth rate
[ ] Check DB sizes and growth rates
[ ] Review the cost of the past 90 days
[ ] Cross-reference contracts signed in past 90 days for SLA / compliance commitments
[ ] Walk through criteria sections 2 and 3 above; tally signals per category
[ ] Compare against decision thresholds
[ ] If graduation indicated:
    [ ] Document evidence
    [ ] Estimate next-phase cost
    [ ] Estimate migration effort
    [ ] Schedule stakeholder review
[ ] If staying: document the reasoning and revisit next quarter
[ ] Confirm observability instrumentation from §5 is still installed and working
```

Save the completed checklist with a date stamp under `axiome-infra/docs/quarterly-reviews/YYYY-QN.md` for audit trail.
