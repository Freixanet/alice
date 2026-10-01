"""Regressions from the real shop: certification, format, counters and line totals."""
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('alice_purchase_prozis', ROOT / 'purchase_prozis.py')
prozis = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = prozis
spec.loader.exec_module(prozis)
spec = importlib.util.spec_from_file_location('alice_prozis_price_test', ROOT / 'purchase_prices.py')
prices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prices)


class ProductPage:
    def __init__(self, options, title='Creatina Creapure® 80 cápsulas'):
        self.options, self.title, self.selected = options, title, None
    def read(self, selector):
        if selector == 'h1.product-name': return self.title
        if 'option-active' in selector: return self.selected['label'] if self.selected else None
    def evaluate(self, script):
        if 'Array.from(document.querySelectorAll' in script:
            return self.options if 'snap-slider-item' in script else ['IMBACK']
        if 'cart summary' in script: return 'https://www.prozis.com/es/es/checkout/index'
        if script == 'location.href': return 'https://www.prozis.com/es/es/prozis/example'
    def click(self, selector, action):
        assert action == 'variant'
        self.selected = next(o for o in self.options if '"' + o['id'] + '"' in selector)


class ProzisTests(unittest.TestCase):
    def test_search_uses_the_shops_own_search_for_any_product(self):
        args = prozis.search_request('Compra la creatina creapure de prozis', 'ES')
        self.assertEqual(args['url'], 'https://www.prozis.com/es/es/search?text=creatina%20creapure')
        self.assertEqual(args['keywords'], ['creati', 'creapu'])
        shirt = prozis.search_request('Compra una camiseta de prozis', 'ES')
        self.assertIn('search?text=camiseta', shirt['url'])
        self.assertIsNone(prozis.search_request('Compra creatina de otra marca', 'ES'))
        self.assertIsNone(prozis.search_request('Compra creapure de prozis', 'US'))

    def test_adapter_does_not_attach_to_a_similar_or_different_origin(self):
        self.assertTrue(prozis.supports('https://www.prozis.com/es/es'))
        for url in ['https://www.prozis.com.attacker.test/es', 'https://prozis.com@attacker.test/es',
                    'http://www.prozis.com/es', 'https://example.com/es']:
            self.assertFalse(prozis.supports(url))

    def test_80_capsules_does_not_select_the_first_320_capsule_option(self):
        page = ProductPage([{'id':'320','label':'320 cápsulas veg.'}, {'id':'80','label':'80 cápsulas veg.'}])
        recipe = prozis.product_recipe(page,{})
        self.assertEqual(recipe['prozis_variant_id'],'80')
        self.assertEqual(page.selected['label'],'80 cápsulas veg.')
        self.assertEqual(recipe['price_basis'],'line_total')
        self.assertEqual(recipe['public_codes'],['IMBACK'])

    def test_revalidation_preserves_the_disclosed_flavour(self):
        page = ProductPage([{'id':'1','label':'Cola'}, {'id':'2','label':'Neutro'}], 'Creapure 300 g')
        self.assertEqual(prozis.product_recipe(page,{})['prozis_variant_id'],'2')
        self.assertEqual(prozis.product_recipe(page,{'prozis_variant_id':'1'})['prozis_variant_id'],'1')
        with self.assertRaises(ValueError): prozis.product_recipe(page,{'prozis_variant_id':'999'})

    def test_a_missing_package_cannot_be_substituted_by_a_larger_one(self):
        page = ProductPage([{'id':'320','label':'320 cápsulas veg.'}])
        with self.assertRaises(ValueError): prozis.product_recipe(page,{})
        self.assertIsNone(page.selected)

    def test_line_total_is_divided_by_the_verified_quantity(self):
        recipe = {'price_basis':'line_total'}
        self.assertEqual(prices.cart_amount('69,98 €','EUR',2,recipe),(3499,'EUR'))
        self.assertEqual(prices.cart_amount('34,99 €','EUR',2,{}),(3499,'EUR'))
        with self.assertRaises(ValueError): prices.cart_amount('69,99 €','EUR',2,recipe)

    def test_certification_is_preserved_even_when_the_brand_matches(self):
        flow = prices.module('purchase_flow')
        with mock.patch.object(flow,'saved_request',return_value=''), mock.patch.object(flow,'verify',return_value=([
            {'id':'test-1','title':'Creatina MicronPure 300 g','url':'https://www.prozis.com/es/es/prozis/micronpure'},
        ],[])):
            import tempfile
            with tempfile.TemporaryDirectory() as folder:
                result = flow.present(Path(folder),'chat',{'options':[{'title':'Creatina MicronPure 300 g','merchant':'Prozis',
                    'url':'https://www.prozis.com/es/es/prozis/micronpure'}]},request='Compra la creatina creapure de prozis')
                self.assertFalse(result['ok'])


if __name__ == '__main__': unittest.main()
