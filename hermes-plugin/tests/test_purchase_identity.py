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


class SizeTests(unittest.TestCase):
    def test_sizes_are_read_and_normalized(self):
        self.assertEqual(flow._sizes("creatina Creapure de 500 g en HSN"), {"500g"})
        self.assertEqual(flow._sizes("Creatina Excell (100% Creapure®) en polvo 500g"), {"500g"})
        self.assertEqual(flow._sizes("bote de 0,5 kg"), {"500g"})
        self.assertEqual(flow._sizes("Creatina Excell 1000mg"), set())


class BundleTests(unittest.TestCase):
    def test_a_pack_is_left_out_when_the_product_alone_was_asked_for(self):
        bundle = __import__("re").compile(r"\bpack\b|\blote\b|\bbundle\b|\bkit\b|\bcombo\b|\bmix\b|\s\+\s", __import__("re").I)
        self.assertTrue(bundle.search("Creatina Excell (100% Creapure®) en polvo + saborizantes - mix pack"))
        self.assertFalse(bundle.search("Creatina Excell (100% Creapure®) en polvo"))
