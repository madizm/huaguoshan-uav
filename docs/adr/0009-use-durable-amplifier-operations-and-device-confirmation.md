# Use durable amplifier operations and device confirmation

Real amplifier control must use PostgreSQL-backed operations, deadlines, authorization, audit events, and a leased command outbox processed by an independent worker; browser timers and direct browser-to-vendor requests are not control mechanisms. Vendor HTTP acceptance records only that a command was dispatched, while the Amplifier Actual State comes from WebSocket status or device telemetry reconciliation. This separates platform intent from device fact, survives process restarts, and preserves the scheduled stop for Omnidirectional Frequency Mode before any start request is sent.

The 60-second Business Duration Limit is enforced by the platform workflow, but the device's 120-second Device Hard Protection cannot prove that limit during a simultaneous platform, network, and device-communication failure. A strict physical 60-second ceiling therefore requires device-side protection or an independent edge watchdog.
