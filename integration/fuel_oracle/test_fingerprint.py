"""Guard the frozen model bytes independently of the semantic oracle."""

import hashlib
from pathlib import Path
import unittest


class ModelFingerprint(unittest.TestCase):
    def check_fingerprint(self, spec_name, frozen_name, sources):
        root = Path(__file__).resolve().parents[2]
        docs = root / "docs/implementation"
        files = [root / source for source in sources] + [docs / spec_name]
        serialized = "\0".join(path.read_text(encoding="utf-8") for path in files)
        digest = hashlib.sha256(serialized.encode("utf-8")).hexdigest()
        self.assertEqual(digest, (docs / frozen_name).read_text(encoding="ascii").strip())

    def test_fuel_v2_model(self):
        self.check_fingerprint("fuel-v2.md", "fuel-v2.sha256", ["cost_model.mbt", "join_fuel.mbt"])
