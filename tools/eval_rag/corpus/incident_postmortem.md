# Incident Postmortem 2026-09-01

## Summary
For 47 minutes all token refreshes failed with 500s.

## Root cause
A deploy rotated the signing keys defined in deploy_runbook.md, but one verifier
was not restarted and kept an old public key.

## Action items
- add automated verifier restarts
- document the rotation in the runbook (done)
- review how the token format is versioned in auth_token_spec.md
