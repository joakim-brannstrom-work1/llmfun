# Authentication Migration Plan

Moving all services from session cookies to JWT access tokens.

1. Phase 1: introduce the token endpoint in the gateway (done).
2. Phase 2: migrate internal services, oldest first.
3. Phase 3: switch the frontend; drop cookie support.

The token format is defined in auth_token_spec.md. Operational steps for the
signing key rotation are in deploy_runbook.md. Open questions were tracked in
the incident postmortem incident_postmortem.md.
