"""UAV model matching and weight class resolution."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import Any, Protocol

logger = logging.getLogger(__name__)


def _text(value: Any) -> str:
    """Convert bytes or other types to string."""
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return str(value)

class AsyncConnection(Protocol):
    async def execute(self, query: str, params: tuple[Any, ...] = ()) -> Any: ...


@dataclass(frozen=True)
class UavModelSpec:
    """UAV model specification with weight class."""
    model_code: str
    weight_class: str
    max_takeoff_weight_kg: float


@dataclass
class UavModelMatcher:
    """Matches observation model strings to UAV specifications.
    
    Rules are evaluated in priority order. Higher priority wins.
    If multiple rules match with the same priority, the first one in the list wins.
    """
    rules: list[tuple[re.Pattern, int, str]]  # (pattern, priority, model_code)
    specs: dict[str, UavModelSpec]  # model_code -> spec

    @classmethod
    async def from_database(cls, conn: AsyncConnection) -> UavModelMatcher:
        """Load matcher rules and specs from database."""
        # Load alias rules
        cursor = await conn.execute(
            """
            SELECT alias_pattern, priority, model_code
            FROM equipment.uav_model_alias
            ORDER BY priority DESC, alias_pattern
            """
        )
        alias_rows = await cursor.fetchall()
        
        rules = []
        for row in alias_rows:
            pattern_str = _text(row["alias_pattern"])
            # Convert SQL LIKE pattern to regex
            # First escape all regex special chars except % and _
            # Then convert % to .* and _ to .
            regex_str = "^"
            for char in pattern_str:
                if char == "%":
                    regex_str += ".*"
                elif char == "_":
                    regex_str += "."
                else:
                    regex_str += re.escape(char)
            regex_str += "$"
            rules.append((re.compile(regex_str, re.IGNORECASE), row["priority"], _text(row["model_code"])))
        
        # Load specs
        cursor = await conn.execute(
            """
            SELECT model_code, weight_class, max_takeoff_weight_kg
            FROM equipment.uav_model_spec
            """
        )
        spec_rows = await cursor.fetchall()
        
        specs = {}
        for row in spec_rows:
            model_code = _text(row["model_code"])
            specs[model_code] = UavModelSpec(
                model_code=model_code,
                weight_class=_text(row["weight_class"]),
                max_takeoff_weight_kg=float(row["max_takeoff_weight_kg"]),
            )
        
        return cls(rules=rules, specs=specs)

    @classmethod
    def from_config(cls, config: dict) -> UavModelMatcher:
        """Load matcher from configuration dict.
        
        Config format:
        {
            "rules": [
                {"pattern": "%Mavic%", "priority": 10, "model_code": "DJI_MAVIC_3E"},
                ...
            ],
            "specs": {
                "DJI_MAVIC_3E": {
                    "weight_class": "light",
                    "max_takeoff_weight_kg": 1.05
                },
                ...
            }
        }
        """
        rules = []
        for rule in config.get("rules", []):
            pattern_str = rule["pattern"]
            # Convert SQL LIKE pattern to regex
            # First escape all regex special chars except % and _
            # Then convert % to .* and _ to .
            regex_str = "^"
            for char in pattern_str:
                if char == "%":
                    regex_str += ".*"
                elif char == "_":
                    regex_str += "."
                else:
                    regex_str += re.escape(char)
            regex_str += "$"
            rules.append((re.compile(regex_str, re.IGNORECASE), rule["priority"], rule["model_code"]))
        
        specs = {}
        for model_code, spec_data in config.get("specs", {}).items():
            specs[model_code] = UavModelSpec(
                model_code=model_code,
                weight_class=spec_data["weight_class"],
                max_takeoff_weight_kg=float(spec_data["max_takeoff_weight_kg"]),
            )
        
        return cls(rules=rules, specs=specs)

    def match(self, observation_model: str | None) -> UavModelSpec | None:
        """Match observation model string to UAV spec.
        
        Returns None if no match or observation_model is None/empty.
        Logs warnings for ambiguous matches (same priority, different model_code).
        """
        if not observation_model:
            return None
        
        # Find all matching rules
        candidates: dict[str, tuple[int, int]] = {}  # model_code -> (priority, rule_index)
        for rule_index, (pattern, priority, model_code) in enumerate(self.rules):
            if pattern.search(observation_model):
                existing = candidates.get(model_code)
                if existing is None or priority > existing[0]:
                    candidates[model_code] = (priority, rule_index)
        
        if not candidates:
            return None
        
        # Check for ambiguity (same priority, different model_code)
        max_priority = max(p for p, _ in candidates.values())
        top_candidates = [code for code, (p, _) in candidates.items() if p == max_priority]
        
        if len(top_candidates) > 1:
            logger.warning(
                "Ambiguous UAV model match for %r: multiple model_codes with priority %d: %s",
                observation_model, max_priority, top_candidates,
            )
        
        # Return the first (highest priority, earliest in rules list)
        best_model_code = min(top_candidates, key=lambda code: candidates[code][1])
        return self.specs.get(best_model_code)
