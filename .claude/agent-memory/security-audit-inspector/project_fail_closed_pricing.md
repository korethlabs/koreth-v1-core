---
name: Koreth fail-closed pricing principle
description: The governing security principle for Koreth audits — never assume/default/invent a value — and the $1-fallback incident that produced it
type: project
---

Koreth's governing security principle (set ~2026-08): **the protocol must never assume, default to, or invent a value. A missing required input must fail the operation closed.** Audit every finding against this, not just against generic DeFi checklists.

**Why:** a high-severity bug was fixed in which four call sites priced *every* borrow asset at exactly $1 whenever `ProtocolCore.priceFeedRegistryAddr` was unset (decimal normalisation passed off as a USD price). On a WETH market that is ~3000x over-borrow plus a health factor that never falls, so no liquidation is possible. It survived review because all live markets were stablecoins (the invented price was accidentally right) and because most tests never configured a registry — the suite agreed with the bug.

**How to apply:**
- Treat "0 means disabled/unlimited/trusted" defaults as suspect, not as neutral. Several guards in the codebase are opt-in and dormant unless a deploy script wires them; flag those as findings even though the code itself is correct.
- Treat a passing test suite as *weak* evidence here — check whether tests exercise the guard or merely agree with its absence.
- Deploy scripts are in audit scope, not out of it. The dangerous state is usually a correct contract left unconfigured, or a local/mock deploy profile with no chain guard.
</content>
</invoke>
