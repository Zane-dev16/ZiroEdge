#!/usr/bin/env python3
"""Fail-closed validator for physical memory calibration JSONL."""

import argparse
import json
import math
from pathlib import Path


class CalibrationValidationError(ValueError):
    """Raised when physical acceptance evidence is incomplete or unsafe."""


def _require(condition, message):
    if not condition:
        raise CalibrationValidationError(message)


def _has_upward_trend(values):
    count = len(values)
    x_mean = (count - 1) / 2
    y_mean = sum(values) / count
    numerator = sum(
        (index - x_mean) * (value - y_mean) for index, value in enumerate(values)
    )
    denominator = sum((index - x_mean) ** 2 for index in range(count))
    return denominator == 0 or numerator / denominator > 0


def validate_records(records, expected_model_id, mode):
    """Validate one run and return its evidence summary."""
    _require(records, "no calibration records")
    _require(mode in {"text", "vision"}, "unknown profile mode")
    _require(
        all(record.get("modelID") == expected_model_id for record in records),
        "mixed or unexpected model IDs",
    )
    _require(
        not any(record.get("checkpoint") == "workloadFailure" for record in records),
        "workload failure recorded",
    )

    baselines = {}
    recoveries = {}
    for record in records:
        cycle = record.get("cycle")
        if record.get("checkpoint") == "cold" and cycle in range(1, 6):
            baselines[cycle] = record["physicalFootprintBytes"]
        if record.get("checkpoint") == "recovery" and cycle in range(1, 6):
            recoveries[cycle] = record["physicalFootprintBytes"]

    _require(set(baselines) == set(range(1, 6)), "missing cycle baseline")
    _require(set(recoveries) == set(range(1, 6)), "missing five-second recovery")
    turns = {
        record.get("turn")
        for record in records
        if record.get("checkpoint") == "firstTextPrefill"
        and record.get("cycle") in range(1, 6)
        and record.get("turn") is not None
    }
    _require(turns == set(range(1, 21)), "missing one or more of 20 prompts")
    checkpoints = {record.get("checkpoint") for record in records}
    _require(
        {"background", "foreground"}.issubset(checkpoints),
        "missing background/foreground evidence",
    )

    image_turns = [
        record
        for record in records
        if record.get("checkpoint") == "firstImageEval"
        and record.get("cycle") in range(1, 6)
    ]
    if mode == "vision":
        _require(
            {record.get("cycle") for record in image_turns} == set(range(1, 6)),
            "missing vision image turns",
        )
    else:
        _require(not image_turns, "text profile unexpectedly evaluated an image")

    for cycle in range(1, 6):
        _require(
            recoveries[cycle] <= baselines[cycle] + 100_000_000,
            f"cycle {cycle} did not recover within 100 MB",
        )
    ordered_recoveries = [recoveries[cycle] for cycle in range(1, 6)]
    _require(
        not _has_upward_trend(ordered_recoveries),
        "post-unload footprint has an upward trend",
    )
    _require(
        min(record.get("processAvailableBytes", 0) for record in records)
        >= 750_000_000,
        "fixed reserve breached",
    )

    peak_deltas = []
    for cycle in range(1, 6):
        cycle_peak = max(
            record["physicalFootprintBytes"]
            for record in records
            if record.get("cycle") == cycle
        )
        peak_deltas.append(max(0, cycle_peak - baselines[cycle]))
    measured_peak = max(peak_deltas)
    rounded_scaled_peak = math.ceil(measured_peak * 1.25 / 100_000_000) * 100_000_000
    return {
        "accepted": True,
        "modelID": expected_model_id,
        "mode": mode,
        "cycles": 5,
        "prompts": 20,
        "measuredFullWorkloadPeakDeltaBytes": measured_peak,
        "safetyMultiplier": 1.25,
        "fixedReserveBytes": 750_000_000,
        "requiredProcessHeadroomBytes": rounded_scaled_peak + 750_000_000,
        "minimumPhysicalRAMBytes": min(
            record["totalPhysicalBytes"] for record in records
        ),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("jsonl", type=Path)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--mode", choices=("text", "vision"), required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()

    _require(args.jsonl.is_file() and args.jsonl.stat().st_size > 0, "missing JSONL")
    try:
        with args.jsonl.open(encoding="utf-8") as stream:
            all_records = [json.loads(line) for line in stream if line.strip()]
    except (OSError, json.JSONDecodeError) as error:
        raise CalibrationValidationError(f"could not read JSONL: {error}") from error
    _require(all_records, "empty JSONL")
    latest_run_id = all_records[-1].get("runID")
    _require(latest_run_id, "latest record has no run ID")
    records = [record for record in all_records if record.get("runID") == latest_run_id]
    summary = validate_records(records, args.model_id, args.mode)
    summary["runID"] = latest_run_id
    args.summary.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    import sys

    sys.stdout.write(json.dumps(summary, sort_keys=True) + "\n")


if __name__ == "__main__":
    try:
        main()
    except (CalibrationValidationError, json.JSONDecodeError, OSError) as error:
        raise SystemExit(f"calibration rejected: {error}") from error
