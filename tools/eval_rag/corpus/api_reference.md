# API Reference

## Endpoints
- POST /auth/token issue an access token (see auth_token_spec.md for the claims)
- POST /auth/refresh rotate a refresh token
- GET /users/{id} fetch a user profile
- GET /health liveness probe

All endpoints require the Authorization header with a bearer token.
Rate limits: 100 requests per minute per client id.
