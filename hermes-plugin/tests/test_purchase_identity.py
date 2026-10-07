import importlib.util
import sys
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("alice_purchase_flow_identity", Path(__file__).parents[1] / "purchase_flow.py")
flow = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = flow
spec.loader.exec_module(flow)


class ShopIdentityTests(unittest.TestCase):
    def test_a_shop_named_by_the_start_of_its_domain_matches(self):
        identity, store_only = flow.requested_identity("Quiero comprar creatina Creapure de 500 g en HSN.")
        self.assertEqual((identity, store_only), ("hsn", True))
        option = {"url": "https://www.hsnstore.com/marcas/raw-series/creatina", "merchant": ""}
        self.assertTrue(flow.matches_identity(option, identity, store_only))
        other = {"url": "https://www.myprotein.es/creatina", "merchant": "Myprotein"}
        self.assertFalse(flow.matches_identity(other, identity, store_only))

    def test_a_name_with_spaces_matches_its_joined_domain(self):
        option = {"url": "https://www.elcorteingles.es/x", "merchant": ""}
        self.assertTrue(flow.matches_identity(option, "el corte ingles", True))


if __name__ == "__main__":
    unittest.main()
