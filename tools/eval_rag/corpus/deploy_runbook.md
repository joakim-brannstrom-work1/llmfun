# Deployment Runbook

## Signing key rotation
Every 90 days rotate the EdDSA signing keys used for access tokens.
1. generate a new key pair in the key ring
2. publish the public key to all verifiers
3. wait one token lifetime (15 minutes)
4. decommission the old private key

## Rollback
If the gateway rejects valid tokens, roll back to the previous release tag.
Database credentials for the token store are in the vault under deploy/tokenstore.

Related documents: auth_token_spec.md defines the token format; db_schema.md
documents the token store tables.
