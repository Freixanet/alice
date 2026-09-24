"""Replies in iMessage and SMS read like text messages, not a wall of markdown."""
import importlib.util
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("alice_text_channel_test", Path(__file__).resolve().parents[1] / "text_channel.py")
tc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tc)

WALL = ("Sí: hoy destacan **la sandwichera multifunción Create por 21,80 €** (antes 54,95 €), el **descuento "
        "de 3 € en Lidl** en compras de 30 € — solo hoy— y **Yakuza 0 Director's Cut para Switch 2 por 19,99 € + "
        "envío**. También aparecen un mini deshumidificador Create a 14,95 €. "
        "[Ver Chollometro](https://www.chollometro.com/ofertas)")


class TextChannelTests(unittest.TestCase):
    def test_a_wall_becomes_short_paragraphs_and_the_link_keeps_its_address(self):
        out = tc.plain(WALL)
        self.assertNotIn("**", out)
        self.assertNotIn("](", out)
        self.assertIn("Ver Chollometro:\nhttps://www.chollometro.com/ofertas", out)
        self.assertIn("\n\nTambién aparecen", out)
        self.assertIn("21,80 €", out)  # decimals are not sentence ends

    def test_lists_and_headings_lose_their_symbols(self):
        self.assertEqual(tc.plain("## Hoy\n- uno\n* dos\n1. tres"), "Hoy\n• uno\n• dos\n• tres")

    def test_only_plain_text_channels_are_changed(self):
        self.assertIsNone(tc.transform(response_text="**hola**", platform="telegram"))
        self.assertEqual(tc.transform(response_text="**hola**", platform="photon"), "hola")
        self.assertIsNone(tc.transform(response_text="hola", platform="photon"))


if __name__ == "__main__":
    unittest.main()
