import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("alice_purchase_promotions", Path(__file__).parents[1] / "purchase_promotions.py")
promotions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(promotions)


class PublicCodeTests(unittest.TestCase):
    def test_a_product_authenticity_code_is_not_a_coupon(self):
        blocks = ["Con sello de calidad oficial. Código 18HR11 - ¡Encuéntranos en la página oficial de Creapure®!",
                  "Tiene un código identificativo que asegura que es auténtico. El de HSN es 18HR11."]
        self.assertEqual(promotions.public_codes(blocks), [])

    def test_a_shop_coupon_is_still_found(self):
        self.assertEqual(promotions.public_codes(["Usa el cupón VERANO10 y llévate un 10% de descuento"]), ["VERANO10"])


if __name__ == "__main__":
    unittest.main()
