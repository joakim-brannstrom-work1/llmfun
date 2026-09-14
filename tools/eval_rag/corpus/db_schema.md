# Database Schema

## Tables
- users: id, email, created_at, status
- token_store: id, user_id, refresh_hash, expires_at, rotated_at
- audit_log: id, actor, action, target, at

The token store is discussed in auth_token_spec.md. Retention policies are in
the data retention appendix of onboarding.md.
