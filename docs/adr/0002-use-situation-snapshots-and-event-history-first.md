# Use Situation Snapshots and Event History First

For the first stage, the platform will model the operational data shape as situation snapshots plus event history, rather than building a full real-time stream-processing platform. This matches the current need: low-altitude airspace event visualization, risk assessment, and response orchestration, while preserving history for traceability and replay of decisions.

## Considered Options

- Build a full real-time event streaming platform first.
- Store only the current state for dashboard display.
- Use situation snapshots for current assessment and event history for traceability, with high-frequency streams added later where needed.

## Consequences

PostGIS/PostgREST, scheduled refreshes, polling, and historical tables are acceptable first-stage mechanisms. High-frequency target tracking, device alarms, and direct countermeasure control should be designed as later incremental real-time channels, not assumed as the baseline architecture.
