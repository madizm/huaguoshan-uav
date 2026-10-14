"""Short-term trajectory prediction for airspace targets and aircraft assets."""

from .domain import (
    MODEL_VERSION,
    ObservationPoint,
    PredictedPoint,
    Prediction,
    PredictionConfig,
    predict_trajectory,
    prepare_window,
)

__all__ = [
    "MODEL_VERSION",
    "ObservationPoint",
    "PredictedPoint",
    "Prediction",
    "PredictionConfig",
    "predict_trajectory",
    "prepare_window",
]
