# Token Specification

This document defines the JWT access token format used by all services.

## Claims
- `sub` subject identifier
- `exp` expiry timestamp; access tokens expire after 15 minutes
- `iat` issued at
- `scp` scope list

Refresh tokens are opaque strings stored server side and are valid for 30 days.
Tokens are signed with EdDSA using the key ring defined in the deployment runbook.

Do not change the claims without updating auth_overview.md.
