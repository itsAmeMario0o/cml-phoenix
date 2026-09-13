import json
import unittest
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent.parent / "config" / "ise" / "template.json"


class TestIseTemplate(unittest.TestCase):
    def setUp(self) -> None:
        self.doc = json.loads(TEMPLATE.read_text())

    def _resource(self, type_name: str) -> dict:
        for res in self.doc["resources"]:
            if res.get("type") == type_name:
                return res
        self.fail(f"no resource of type {type_name}")

    def test_vm_image_and_plan(self) -> None:
        vm = self._resource("Microsoft.Compute/virtualMachines")
        img = vm["properties"]["storageProfile"]["imageReference"]
        self.assertEqual(img["sku"], "cisco-ise_3_5")
        self.assertEqual(img["version"], "3.5.527")
        self.assertEqual(vm["plan"]["name"], "cisco-ise_3_5")

    def test_role_tags_on_disposable_resources(self) -> None:
        for type_name in (
            "Microsoft.Compute/virtualMachines",
            "Microsoft.Network/networkInterfaces",
            "Microsoft.Network/publicIPAddresses",
        ):
            tags = self._resource(type_name).get("tags", {})
            self.assertEqual(tags.get("role"), "ise", type_name)
            self.assertEqual(tags.get("project"), "cml-azure-lab", type_name)


if __name__ == "__main__":
    unittest.main()
