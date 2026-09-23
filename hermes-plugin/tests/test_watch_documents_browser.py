"""Page watches, bank statements, PDF forms and the shared-browser switch.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(filename, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


watch = load("page_watch.py", "alice_page_watch_test")
documents = load("documents.py", "alice_documents_test")
browser = load("browser_live.py", "alice_browser_live_test")


class WatchNewsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def watch(self, uuid, info, file):
        meta = watch._meta(self.root)
        meta[uuid] = {"url": "https://example.com/p", "label": "Silla", "state": {}, **info}
        watch._save_meta(self.root, meta)
        self.file(uuid, file)

    def file(self, uuid, data):
        folder = self.root / watch.HOME_DIR / "data" / uuid
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "watch.json").write_text(json.dumps(data))

    U = "6a930cb7-adf5-4f8f-81e5-8740aa231868"

    def test_a_price_under_the_threshold_is_news_once(self):
        self.watch(self.U, {"kind": "price", "below": 50}, {"last_checked": 1, "restock": {"price": 59.99, "currency": "EUR"}})
        self.assertEqual(watch.check(self.root), [])
        self.file(self.U, {"last_checked": 2, "restock": {"price": 45.0, "currency": "EUR"}})
        news = watch.check(self.root)
        self.assertEqual(len(news), 1)
        self.assertIn("45,00 EUR", news[0]["detail"])
        self.assertEqual(watch.check(self.root), [])
        self.file(self.U, {"last_checked": 3, "restock": {"price": 60.0, "currency": "EUR"}})
        watch.check(self.root)
        self.file(self.U, {"last_checked": 4, "restock": {"price": 49.0, "currency": "EUR"}})
        self.assertEqual(len(watch.check(self.root)), 1)

    def test_without_a_threshold_any_drop_is_news(self):
        self.watch(self.U, {"kind": "price", "below": None}, {"last_checked": 1, "restock": {"price": 20}})
        self.assertEqual(watch.check(self.root), [])
        self.file(self.U, {"last_checked": 2, "restock": {"price": 25}})
        self.assertEqual(watch.check(self.root), [])
        self.file(self.U, {"last_checked": 3, "restock": {"price": 18}})
        self.assertIn("Ha bajado", watch.check(self.root)[0]["detail"])

    def test_stock_back_and_text_appearing(self):
        self.watch(self.U, {"kind": "stock"}, {"last_checked": 1, "restock": {"in_stock": False}})
        self.assertEqual(watch.check(self.root), [])
        self.file(self.U, {"last_checked": 2, "restock": {"in_stock": True, "price": 10}})
        self.assertEqual(watch.check(self.root)[0]["what"], "stock")
        other = "11111111-2222-3333-4444-555555555555"
        self.watch(other, {"kind": "text", "text": "Entradas disponibles"}, {"last_checked": 1})
        pages = iter(["Agotado", "¡ENTRADAS DISPONIBLES ya!"])
        latest = lambda uuid: next(pages) if uuid == other else None  # noqa: E731
        self.assertEqual([n for n in watch.check(self.root, latest_text=latest) if n["id"] == other], [])
        news = [n for n in watch.check(self.root, latest_text=latest) if n["id"] == other]
        self.assertEqual(news[0]["what"], "text")

    def test_initial_stock_is_not_a_restock(self):
        self.watch(self.U, {"kind": "stock"}, {"last_checked": 1, "restock": {"in_stock": True}})
        self.assertEqual(watch.check(self.root), [])
        self.file(self.U, {"last_checked": 2, "restock": {"in_stock": False}})
        self.assertEqual(watch.check(self.root), [])
        self.file(self.U, {"last_checked": 3, "restock": {"in_stock": True}})
        self.assertEqual(len(watch.check(self.root)), 1)

    def test_watch_uses_requested_check_interval(self):
        with mock.patch.object(watch, "_public", return_value="https://example.com/p"), \
                mock.patch.object(watch, "start", return_value=True), \
                mock.patch.object(watch, "_api", return_value={"uuid": self.U}) as api:
            watch.create(self.root, url="https://example.com/p", kind="change", every_minutes=30)
        body = api.call_args.args[3]
        self.assertEqual(body["time_between_check"], {"minutes": 30})
        self.assertIs(body["time_between_check_use_default"], False)

    def test_a_page_failing_for_a_day_is_said_once(self):
        self.watch(self.U, {"kind": "change"}, {"last_checked": 1, "last_error": "403"})
        self.assertEqual(watch.check(self.root, now=1000), [])
        self.assertEqual(watch.check(self.root, now=1000 + 25 * 3600)[0]["what"], "error")
        self.assertEqual(watch.check(self.root, now=1000 + 26 * 3600), [])

    def test_facts_are_empty_without_news(self):
        self.assertEqual(watch.facts([]), "")
        line = watch.facts([{"label": "Silla", "url": "https://x.es", "detail": "Ha bajado."}])
        self.assertEqual(line, "- [Silla](https://x.es): Ha bajado.")

    def test_only_public_pages_can_be_watched(self):
        for url in ("http://127.0.0.1/", "http://localhost:5057/", "file:///etc/passwd", "http://10.0.0.1/",
                    "https://example.com:8443/", "https://user:pw@example.com/"):
            with self.assertRaises(watch.WatchError, msg=url):
                watch._public(url)
        with mock.patch.object(watch.socket, "getaddrinfo", return_value=[(0, 0, 0, "", ("127.0.0.1", 443))]):
            with self.assertRaises(watch.WatchError):
                watch._public("https://looks-public.example/")

    def test_the_routine_is_created_once(self):
        calls = []
        run = lambda argv, **_: calls.append(argv) or mock.Mock(returncode=0, stdout="", stderr="")  # noqa: E731
        self.assertEqual(watch.install_routine(self.root, run=run, hermes="hermes"), "created")
        self.assertTrue((self.root / "scripts" / watch.SCRIPT).is_file())
        self.assertIn("--script", calls[0])
        (self.root / "cron").mkdir()
        (self.root / "cron" / "jobs.json").write_text(json.dumps({"jobs": [{"name": watch.ROUTINE}]}))
        self.assertEqual(watch.install_routine(self.root, run=run, hermes="hermes"), "exists")


class SpendingTests(unittest.TestCase):
    def write(self, text, name="movimientos.csv"):
        self.temp = tempfile.TemporaryDirectory()
        path = Path(self.temp.name) / name
        path.write_bytes(text.encode("cp1252"))
        self.addCleanup(self.temp.cleanup)
        return str(path)

    def test_a_spanish_bank_export_adds_up(self):
        path = self.write(
            "Cuenta: ES00 1234\nMovimientos del periodo\n\n"
            "Fecha;Fecha valor;Concepto;Importe;Saldo\n"
            "02/09/2026;02/09/2026;COMPRA MERCADONA VALENCIA;-45,30;1.200,00\n"
            "03/09/2026;03/09/2026;NOMINA SEPTIEMBRE;1.850,00;3.050,00\n"
            "05/09/2026;05/09/2026;PAGO NETFLIX.COM;-12,99;3.037,01\n"
            "10/09/2026;10/09/2026;RECIBO IBERDROLA;-60,00;2.977,01\n"
            "12/09/2026;12/09/2026;BAR PEPE MADRID;-8,50;2.968,51\n"
            "15/09/2026;15/09/2026;XYZ RARO SL;-100,00;2.868,51\n")
        result = documents.spending(path)
        self.assertEqual(result["income"], 1850.0)
        self.assertEqual(result["spent"], 226.79)
        self.assertEqual(result["net"], 1623.21)
        names = {c["name"]: c["amount"] for c in result["categories"]}
        self.assertEqual(names["Supermercado"], 45.3)
        self.assertEqual(names["Suscripciones"], 12.99)
        self.assertEqual(names["Hogar y suministros"], 60.0)
        self.assertEqual(names["Restaurantes"], 8.5)
        self.assertEqual(result["uncategorized"], ["XYZ RARO SL"])
        self.assertEqual(result["from"], "2026-09-02")
        fixed = documents.spending(path, rules={"xyz raro": "Hogar y suministros"})
        self.assertEqual({c["name"]: c["amount"] for c in fixed["categories"]}["Hogar y suministros"], 160.0)

    def test_debit_and_credit_columns_and_english_headers(self):
        path = self.write("Date,Description,Debit,Credit\n2026-09-01,Uber trip,12.40,\n2026-09-02,Refund,,5.00\n")
        result = documents.spending(path)
        self.assertEqual(result["spent"], 12.4)
        self.assertEqual(result["income"], 5.0)
        self.assertEqual(result["categories"][0]["name"], "Transporte")

    def test_a_file_that_is_not_a_statement_says_so(self):
        with self.assertRaises(documents.DocumentError):
            documents.spending(self.write("hola,adios\n1,2\n"))
        with self.assertRaises(documents.DocumentError):
            documents.spending("relative.csv")

    def test_amounts_in_every_notation(self):
        for raw, value in (("1.234,56", 1234.56), ("-12,30", -12.3), ("1,234.56", 1234.56), ("(9.99)", -9.99),
                           ("45 €", 45.0), ("", None)):
            self.assertEqual(documents._amount(raw), value, raw)


class PdfFormTests(unittest.TestCase):
    def setUp(self):
        try:
            self.pypdf = documents._pypdf()
        except documents.DocumentError:
            self.skipTest("pypdf is not installed in the plugin's vendor folder")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def form(self):
        from pypdf.generic import ArrayObject, DictionaryObject, NameObject, NumberObject, TextStringObject
        writer = self.pypdf.PdfWriter()
        page = writer.add_blank_page(300, 300)
        field = DictionaryObject({
            NameObject("/FT"): NameObject("/Tx"), NameObject("/T"): TextStringObject("nombre"),
            NameObject("/Type"): NameObject("/Annot"), NameObject("/Subtype"): NameObject("/Widget"),
            NameObject("/Rect"): ArrayObject([NumberObject(50), NumberObject(200), NumberObject(250), NumberObject(220)]),
        })
        ref = writer._add_object(field)
        page[NameObject("/Annots")] = ArrayObject([ref])
        writer._root_object[NameObject("/AcroForm")] = DictionaryObject({NameObject("/Fields"): ArrayObject([ref])})
        path = Path(self.temp.name) / "solicitud.pdf"
        with open(path, "wb") as handle:
            writer.write(handle)
        return str(path)

    def test_read_then_fill(self):
        path = self.form()
        read = documents.form_read(path)
        self.assertEqual([f["name"] for f in read["fields"]], ["nombre"])
        filled = documents.form_fill(path, {"nombre": "Ana García", "inventado": "x"})
        self.assertTrue(filled["path"].endswith("solicitud-rellenado.pdf"))
        self.assertEqual(filled["unknown"], ["inventado"])
        self.assertEqual(documents.form_read(filled["path"])["fields"][0]["value"], "Ana García")
        again = documents.form_fill(path, {"nombre": "Otra persona"})
        self.assertNotEqual(filled["path"], again["path"])
        self.assertEqual(documents.form_read(filled["path"])["fields"][0]["value"], "Ana García")


class BrowserSwitchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "profiles" / "inbox").mkdir(parents=True)
        (self.root / "config.yaml").write_text("browser:\n  inactivity_timeout: 120\n")
        (self.root / "profiles" / "inbox" / "config.yaml").write_text("browser:\n  cdp_url: ws://elsewhere:9000\n")
        self.writes = {}

    def tearDown(self):
        browser.stop_all()
        self.temp.cleanup()

    def set_cdp(self, home, value):
        import yaml
        path = home / "config.yaml"
        config = yaml.safe_load(path.read_text()) or {}
        previous = (config.get("browser") or {}).get("cdp_url")
        config.setdefault("browser", {})
        if value:
            config["browser"]["cdp_url"] = value
        else:
            config["browser"].pop("cdp_url", None)
        path.write_text(yaml.safe_dump(config))
        return previous

    def test_enable_points_every_profile_and_disable_restores(self):
        with mock.patch.object(browser, "launch", return_value=True), \
                mock.patch.object(browser, "reachable", return_value=False):
            browser.enable(self.root, self.set_cdp)
        self.assertEqual(browser.configured_url(self.root), browser.MANAGED_URL)
        self.assertIn(browser.MANAGED_URL, (self.root / "profiles" / "inbox" / "config.yaml").read_text())
        self.assertTrue(browser.managed(self.root))
        with mock.patch.object(browser, "reachable", return_value=False):
            browser.disable(self.root, self.set_cdp)
        self.assertEqual(browser.configured_url(self.root), "")
        self.assertIn("ws://elsewhere:9000", (self.root / "profiles" / "inbox" / "config.yaml").read_text())
        self.assertFalse(browser.managed(self.root))

    def test_a_browser_on_another_machine_is_never_driven(self):
        (self.root / "config.yaml").write_text("browser:\n  cdp_url: http://192.168.1.5:9222\n")
        with self.assertRaises(browser.BrowserError):
            browser.frame(self.root, 0, 0.1)
        self.assertFalse(browser.reachable("http://192.168.1.5:9222"))

    def test_only_known_keys_and_web_addresses(self):
        cast = browser.Screencast.__new__(browser.Screencast)
        cast.meta, cast.touched, cast._socket = {}, 0, None
        cast._send_lock = __import__("threading").Lock()
        sent = []
        cast._send = lambda method, params: sent.append((method, params))
        with self.assertRaises(browser.BrowserError):
            cast.act({"kind": "key", "key": "F12"})
        with self.assertRaises(browser.BrowserError):
            cast.act({"kind": "navigate", "url": "javascript:alert(1)"})
        cast.act({"kind": "navigate", "url": "example.com"})
        self.assertEqual(sent[-1], ("Page.navigate", {"url": "https://example.com"}))
        cast.act({"kind": "tap", "x": 0.5, "y": 0.5})
        self.assertEqual([m for m, _ in sent[-3:]], ["Input.dispatchMouseEvent"] * 3)


if __name__ == "__main__":
    unittest.main()
