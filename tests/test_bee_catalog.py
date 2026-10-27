import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BeeCatalogTest(unittest.TestCase):
    def test_catalog_covers_climate_species_and_references(self):
        catalog = json.loads((ROOT / "src/bee-catalog.json").read_text())
        climate = json.loads((ROOT / "src/climate-data.json").read_text())
        species = {row["uid"] for row in catalog["species"]}

        self.assertTrue(catalog["completeForClientSpecies"])
        self.assertEqual(species, set(climate))
        self.assertEqual(176, len(species))
        for mutation in catalog["mutations"]:
            self.assertIn(mutation["result"], species)
            self.assertTrue(set(mutation["parents"]).issubset(species))

        boggy = [row for row in catalog["mutations"] if row["result"] == "extrabees.species.boggy"]
        self.assertIn(["forestry.speciesBoggy", "extrabees.species.swamp"],
                      [row["parents"] for row in boggy])


if __name__ == "__main__":
    unittest.main()
