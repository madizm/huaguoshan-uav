# Use Airspace Grid as Core Spatial Index

We will use BeiDou/GGER airspace grids as the platform's core spatial index and situation aggregation unit, not merely as a Cesium display layer. Source objects still keep precise coordinates or PostGIS geometries, while grid mappings support fast lookup, neighborhood queries, risk overlay, multi-scale aggregation, and large-screen expression across targets, constraints, environmental factors, capability coverage, and emergency resources.

## Considered Options

- Use only precise PostGIS geometries for all spatial reasoning.
- Use BeiDou/GGER grids only as a visual overlay.
- Use BeiDou/GGER grids as a core spatial index while preserving precise geometries.

## Consequences

The platform needs explicit grid-mapping pipelines and must keep grid-derived state explainable back to source geometries and observations. Spatially precise calculations remain in PostGIS; grids are used for indexing, aggregation, neighborhood reasoning, and situation visualization.
