# Authentication Overview

The authentication subsystem was refactored in Q3. Access tokens are short lived and refresh
tokens rotate on every use. The exact token claims and lifetimes are defined in the token
specification document (see auth_token_spec.md). The migration schedule is tracked in
auth_migration_plan.md.

# Notes
The old session cookie mechanism was deprecated. All services must use the new token flow.
