"""Tests for UAV model matcher."""

import pytest

from backend.risk_engine.uav_model import UavModelMatcher, UavModelSpec


@pytest.fixture
def sample_config():
    """Sample configuration for testing."""
    return {
        "rules": [
            {"pattern": "%Mavic 3E%", "priority": 10, "model_code": "DJI_MAVIC_3E"},
            {"pattern": "%Mavic 3T%", "priority": 10, "model_code": "DJI_MAVIC_3T"},
            {"pattern": "%Mavic 3%", "priority": 5, "model_code": "DJI_MAVIC_3"},
            {"pattern": "%Air 3S%", "priority": 10, "model_code": "DJI_AIR_3S"},
            {"pattern": "%Air 3s%", "priority": 10, "model_code": "DJI_AIR_3S"},
            {"pattern": "%Air 3%", "priority": 5, "model_code": "DJI_AIR_3"},
            {"pattern": "%Mini 5%", "priority": 10, "model_code": "DJI_MINI_5_PRO"},
            {"pattern": "%Mini%", "priority": 1, "model_code": "DJI_MINI_GENERIC"},
        ],
        "specs": {
            "DJI_MAVIC_3E": {"weight_class": "light", "max_takeoff_weight_kg": 1.05},
            "DJI_MAVIC_3T": {"weight_class": "light", "max_takeoff_weight_kg": 1.05},
            "DJI_MAVIC_3": {"weight_class": "light", "max_takeoff_weight_kg": 0.958},
            "DJI_AIR_3S": {"weight_class": "light", "max_takeoff_weight_kg": 0.724},
            "DJI_AIR_3": {"weight_class": "light", "max_takeoff_weight_kg": 0.720},
            "DJI_MINI_5_PRO": {"weight_class": "micro", "max_takeoff_weight_kg": 0.249},
            "DJI_MINI_GENERIC": {"weight_class": "micro", "max_takeoff_weight_kg": 0.249},
        },
    }


@pytest.fixture
def matcher(sample_config):
    """Create matcher from sample config."""
    return UavModelMatcher.from_config(sample_config)


def test_match_exact_model(matcher):
    """Test exact model match."""
    spec = matcher.match("DJI-Mavic 3E")
    assert spec is not None
    assert spec.model_code == "DJI_MAVIC_3E"
    assert spec.weight_class == "light"


def test_match_case_insensitive(matcher):
    """Test case-insensitive matching."""
    spec = matcher.match("DJI-AIR 3S")
    assert spec is not None
    assert spec.model_code == "DJI_AIR_3S"

    spec = matcher.match("DJI-Air 3s")
    assert spec is not None
    assert spec.model_code == "DJI_AIR_3S"


def test_match_higher_priority_wins(matcher):
    """Test that higher priority rule wins when multiple match."""
    # "DJI-Air 3S" matches both %Air 3S% (priority 10) and %Air 3% (priority 5)
    spec = matcher.match("DJI-Air 3S")
    assert spec is not None
    assert spec.model_code == "DJI_AIR_3S"  # Should match the higher priority rule

    # "DJI-Air 3" matches only %Air 3% (priority 5)
    spec = matcher.match("DJI-Air 3")
    assert spec is not None
    assert spec.model_code == "DJI_AIR_3"


def test_match_no_match(matcher):
    """Test no match returns None."""
    spec = matcher.match("Unknown-Model-X")
    assert spec is None


def test_match_none_input(matcher):
    """Test None input returns None."""
    spec = matcher.match(None)
    assert spec is None


def test_match_empty_string(matcher):
    """Test empty string returns None."""
    spec = matcher.match("")
    assert spec is None


def test_match_generic_fallback(matcher):
    """Test generic fallback when specific model not matched."""
    # "DJI-Mini 2" matches %Mini% (priority 1) but not %Mini 5% (priority 10)
    spec = matcher.match("DJI-Mini 2")
    assert spec is not None
    assert spec.model_code == "DJI_MINI_GENERIC"


def test_match_with_prefix_codes(matcher):
    """Test matching with DJI prefix codes like DJI-73-Mini 3 Pro."""
    spec = matcher.match("DJI-73-Mini 3 Pro")
    assert spec is not None
    # Should match %Mini 5% ? No, "Mini 3" doesn't match "Mini 5"
    # Should match %Mini% (priority 1)
    assert spec.model_code == "DJI_MINI_GENERIC"


def test_match_with_variant_names(matcher):
    """Test matching variant names like DJI-Mini5 pro."""
    # "DJI-Mini5 pro" doesn't match %Mini 5% (space required)
    # Should match %Mini% (priority 1)
    spec = matcher.match("DJI-Mini5 pro")
    assert spec is not None
    assert spec.model_code == "DJI_MINI_GENERIC"


def test_matcher_from_empty_config():
    """Test creating matcher from empty config."""
    matcher = UavModelMatcher.from_config({"rules": [], "specs": {}})
    assert len(matcher.rules) == 0
    assert len(matcher.specs) == 0
    assert matcher.match("DJI-Mavic 3E") is None


def test_matcher_spec_attributes(matcher):
    """Test that matched spec has correct attributes."""
    spec = matcher.match("DJI-Mini 5 Pro")
    assert spec is not None
    assert spec.model_code == "DJI_MINI_5_PRO"
    assert spec.weight_class == "micro"
    assert spec.max_takeoff_weight_kg == 0.249
