# Use Defense Rings for Target Risk Assessment

The target-entry risk scenario uses two-dimensional circular Defense Rings defined by a protected-object center and a radius in meters, without altitude limits; it does not use the legacy `airspace.no_fly_zone` or `airspace.temp_control_zone` tables. For an Airspace Target at an assessment instant, eligible overlapping rings yield **one** selected ring ordered by priority descending, then ring level descending, then ID ascending; ring level informs the score but does not itself equal the event Risk Level. We chose this instead of reusing regulatory zone types or aggregating scores across overlaps so spatial meaning and audit results remain unambiguous.

## Consequences

The shared Airspace Event workbench decision in ADR-0003 remains valid; its old scenario name and typed evidence must be updated to Defense Ring entry. Legacy zone tables and APIs are not removed until other consumers have migrated. Ring centers/radii and scoring rules must be versioned for replay, with default values defined in `docs/defense-ring-risk-model-v1.md`.
