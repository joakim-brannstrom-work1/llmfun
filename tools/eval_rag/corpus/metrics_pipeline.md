# Metrics Pipeline

Raw events are written to the collector, aggregated hourly, and stored in the
metrics warehouse. Dashboards read from the warehouse.

SLOs:
- API availability 99.9%
- token issuance latency p99 < 120 ms
- refresh failure rate < 0.1%

Alerting rules live with the dashboards. No authentication details here;
token-related SLOs are described in incidents when they break (see
incident_postmortem.md).
