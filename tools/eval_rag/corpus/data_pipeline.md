# Data Pipeline

The data pipeline ingests product events from the message bus. Each event is
validated against the schema registry, enriched with geo data, and written to
the analytics store.

Stages:
1. ingest: consume from the bus with at-least-once delivery
2. validate: schema check, drop malformed events
3. enrich: geo and user agent lookup
4. store: batch inserts every 5 seconds

Operational notes: the pipeline is unrelated to authentication, but its service
account tokens are issued by the same gateway (see api_reference.md).
