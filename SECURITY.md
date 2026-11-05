# Security Policy

## Status of this code

Koreth is **pre-beta and has not been audited**. The contracts in this repository are
**not production-ready** and must not be used to custody funds. They have not completed
an external security review, parameters are not final, and the deployed addresses are
test deployments only. Assume that bugs capable of causing total loss of funds are
present.

## Supported versions

Only `main` is supported. Tags, branches and prior commits receive no security fixes;
a report is only acted on if it still reproduces against `main`.

## Reporting a vulnerability

Use **GitHub private vulnerability reporting**: open the repository's **Security** tab
and press **Report a vulnerability**. That creates a private advisory visible only to
the reporter and the maintainers, and it is the channel for all security reports.

Please **do not** open a public issue, a pull request, a discussion, or any other public
thread for a suspected vulnerability. Public disclosure before a fix exposes anyone
running the code.

A useful report includes the affected contract and function, the invariant you believe
is broken, the preconditions an attacker needs, and the impact. A Foundry test that
demonstrates the behaviour is the most helpful thing you can send, since it removes any
ambiguity about whether the issue reproduces.

## What to expect

Reports are reviewed on a best-effort basis. Koreth is a small team and there is **no
response-time commitment** — no acknowledgement SLA, no fix deadline, and no guarantee
that a given report will be acted on.

There is **no bug bounty programme**. No payment, reward or other compensation is
offered for a report. Please do not submit one expecting a bounty.

## Scope

In scope is everything under `src/` in this repository: position custody and collateral
accounting, debt and share accounting, liquidation, the DEX adapters, the price and LP
oracles, risk configuration, the circuit breaker and access control — plus the
deployment scripts under `script/` where a mistake there would produce an unsafe
configuration on chain.

Out of scope here are the periphery contracts, the off-chain services and the web
interface, which live in their own repositories. A report about one of those is still
welcome through this repository's Security tab; say which component you were looking at
so it can be routed.
