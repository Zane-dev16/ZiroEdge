import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "validate_memory_calibration.py"
SPEC = importlib.util.spec_from_file_location(
    "validate_memory_calibration", MODULE_PATH
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load calibration validator")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
CalibrationValidationError = MODULE.CalibrationValidationError
validate_records = MODULE.validate_records


class ValidateMemoryCalibrationTests(unittest.TestCase):
    def records(self):
        records = []
        run_id = "run"
        model_id = "gemma-4-e4b-q4-text-calibration"
        for cycle in range(1, 6):
            baseline = 1000 - cycle
            records.append(self.record(run_id, model_id, "cold", cycle, None, baseline))
            for offset in range(1, 5):
                turn = (cycle - 1) * 4 + offset
                records.append(
                    self.record(run_id, model_id, "firstTextPrefill", cycle, turn, 1500)
                )
            records.append(
                self.record(run_id, model_id, "recovery", cycle, None, baseline)
            )
        records.append(self.record(run_id, model_id, "background", 5, 20, 995))
        records.append(self.record(run_id, model_id, "foreground", 5, 20, 995))
        return records

    def record(self, run_id, model_id, checkpoint, cycle, turn, footprint):
        return {
            "runID": run_id,
            "modelID": model_id,
            "checkpoint": checkpoint,
            "cycle": cycle,
            "turn": turn,
            "physicalFootprintBytes": footprint,
            "processAvailableBytes": 1_000_000_000,
            "totalPhysicalBytes": 8_054_095_872,
        }

    def test_complete_text_run_calculates_formula(self):
        summary = validate_records(
            self.records(), "gemma-4-e4b-q4-text-calibration", "text"
        )
        self.assertTrue(summary["accepted"])
        self.assertEqual(summary["cycles"], 5)
        self.assertEqual(summary["prompts"], 20)
        self.assertEqual(summary["requiredProcessHeadroomBytes"], 850_000_000)

    def test_cycle_zero_warmup_is_excluded_from_measured_prompt_count(self):
        records = self.records()
        records.extend(
            [
                self.record(
                    "run",
                    "gemma-4-e4b-q4-text-calibration",
                    "firstTextPrefill",
                    0,
                    None,
                    1600,
                ),
                self.record(
                    "run",
                    "gemma-4-e4b-q4-text-calibration",
                    "firstImageEval",
                    0,
                    None,
                    1700,
                ),
            ]
        )
        summary = validate_records(records, "gemma-4-e4b-q4-text-calibration", "text")
        self.assertTrue(summary["accepted"])
        self.assertEqual(summary["prompts"], 20)

    def test_missing_record_fails_closed(self):
        records = [
            record for record in self.records() if record["checkpoint"] != "foreground"
        ]
        with self.assertRaises(CalibrationValidationError):
            validate_records(records, "gemma-4-e4b-q4-text-calibration", "text")


if __name__ == "__main__":
    unittest.main()
