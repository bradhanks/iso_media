# SOC 2 Readiness — PerfectPaper

## What this package is

This directory is an **auditor-facing readiness artifact** for PerfectPaper's SOC 2 Type II engagement. It documents the system under examination, maps Trust Services Criteria controls to concrete code and configuration, records the evidence available today, and catalogues the open gaps that must be closed before a Type II opinion can be issued.

This is a **readiness artifact, not an audit report.** It has not been reviewed or issued by an independent CPA firm. It is maintained by the engineering team to make the audit process tractable and to hold engineering accountable for closing gaps on a schedule.

---

## SOC 2 Type I vs. Type II

**Type I** is a point-in-time attestation: the auditor examines whether controls are designed appropriately as of a single date. It answers the question "are the right controls in place today?"

**Type II** is an over-a-period attestation: the auditor examines whether controls operated effectively throughout a defined audit window, typically six to twelve months. It answers "did those controls actually work, consistently, for the whole period?" Type II is the standard demanded by enterprise procurement and most security questionnaires.

PerfectPaper is targeting **Type II**. The audit period and the engaged auditor are both **TBD**. All date and auditor fields in this package use `TBD` as a placeholder; the engineering team must not substitute invented values.

---

## How to use the control map

The primary artifact is `controls.md`. Each row carries a status drawn from the following legend:

| Status | Meaning |
|---|---|
| **Implemented** | The control is in production code, tested, and produces auditable evidence today. |
| **Partial** | Core code exists but at least one material requirement is missing (e.g., a scaffold is in place but not yet wired, or encryption is deferred to a TODO). |
| **Process** | The control is satisfied by a documented human or engineering process rather than automated code; evidence is procedural. |
| **Gap** | No code or documented process satisfies the criterion. This is a known deficiency that must be remediated before the audit window opens or closed with a compensating control. |

Every Gap and Partial row links to either a `TODO()` tag in the codebase (greppable) or a future specification number, so each gap has an owner and a path to resolution.

---

## Audit information

| Field | Value |
|---|---|
| Audit firm | TBD |
| Audit period start | TBD |
| Audit period end | TBD |
| Report issue date | TBD |
| Trust Services Criteria in scope | Security (CC1–CC9), Availability (A1), Confidentiality (C1) |
| Management contact | TBD |
| Engineering contact | TBD |

---

## Files in this package

| File | Purpose |
|---|---|
| `README.md` | This file — orientation, legend, audit metadata |
| `readiness.md` | System description, trust boundary, in-scope criteria, overall posture |
| `controls.md` | Full CC1–CC9, A1, and C1 control-to-code matrix |
| `evidence.md` | Concrete artifacts proving each Implemented or Partial control |
| `gaps.md` | Consolidated open gaps with criterion, TODO tag, and remediation path |

---

## Voice and maintenance

This documentation is written in a measured, precise register consistent with the PerfectPaper editorial voice. It is intended for a technically literate auditor, not a general audience. Claims must be accurate: do not overstate control strength or mark a partial control as implemented. When in doubt, flag the uncertainty and note it as requiring review.

This package is a living document. It should be updated at the close of every specification cycle that changes the security posture, and reviewed in full before the audit window opens.
