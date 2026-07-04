# Use Shared Airspace Event Workbench for MVP Scenarios

The MVP will route both no-fly/control-zone intrusion events and UAV forest-fire patrol warnings into the same airspace event workbench instead of building separate modules and queues. Both scenarios reuse the same lifecycle, risk level, response priority, event claiming, responsible party, response plan candidates, closure basis, and decision evidence chain; scenario-specific differences belong in event type, evidence structure, confirmation windows, and rule templates.

## Considered Options

- Build separate modules and event queues for intrusion handling and forest-fire patrol warnings.
- Use one shared airspace event workbench with event types and scenario-specific evidence/rules.

## Consequences

The workbench, event history, claiming workflow, and review experience remain unified across MVP scenarios. Scenario implementations must not fork lifecycle or responsibility semantics; they should extend the shared event model with typed evidence and scenario-specific rules.
