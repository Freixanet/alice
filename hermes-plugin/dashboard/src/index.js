// Alice tab for the Hermes dashboard. Built into dist/index.js (an IIFE) by
// hermes-plugin/build.sh; React and the UI kit come from the dashboard's Plugin SDK,
// and only the QR encoder is bundled.
import QRCode from "qrcode";

const SDK = window.__HERMES_PLUGIN_SDK__;
const { React } = SDK;
const { useCallback, useEffect, useState } = SDK.hooks;
const { Badge, Button, Card, CardContent, CardHeader, CardTitle } =
  SDK.components;
const h = React.createElement;

function secondsLeft(expiresAt, now) {
  const end = Date.parse(expiresAt);
  return Number.isFinite(end) ? Math.max(0, Math.round((end - now) / 1000)) : 0;
}

function ConnectAlice() {
  const [session, setSession] = useState(null);
  const [qr, setQr] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);

  const mint = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const next = await SDK.fetchJSON("/api/plugins/alice/pairing/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      });
      const image = await QRCode.toDataURL(next.payload, {
        errorCorrectionLevel: "M",
        margin: 2,
        width: 320,
      });
      setSession(next);
      setQr(image);
    } catch (failure) {
      setSession(null);
      setQr(null);
      setError((failure && failure.message) || String(failure));
    } finally {
      setBusy(false);
    }
  }, []);

  const remaining = session ? secondsLeft(session.expires_at, now) : 0;
  const expired = Boolean(session) && remaining === 0;
  const name =
    (session && (session.profile_display_name || session.profile)) || "Hermes";

  return h(
    Card,
    null,
    h(CardHeader, null, h(CardTitle, null, "Connect Alice")),
    h(
      CardContent,
      { className: "flex flex-col gap-4" },
      h(
        "p",
        { className: "text-sm text-muted-foreground" },
        "Show a one-time QR code, then scan it with the iPhone's Camera or with Alice (Connect → Scan pairing QR). " +
          "No addresses, ports or keys to copy.",
      ),
      qr && !expired
        ? h(
            "div",
            { className: "flex flex-col items-center gap-3" },
            h("img", {
              src: qr,
              alt: "Alice pairing QR code",
              width: 320,
              height: 320,
              style: {
                imageRendering: "pixelated",
                background: "white",
                borderRadius: 12,
              },
            }),
            h(Badge, null, `Pairs with ${name} · expires in ${remaining}s`),
          )
        : null,
      expired
        ? h("p", { className: "text-sm" }, "This code expired. Show a new one.")
        : null,
      error ? h("p", { className: "text-sm text-destructive" }, error) : null,
      h(
        Button,
        { onClick: mint, disabled: busy },
        busy
          ? "Preparing…"
          : qr && !expired
            ? "Show a new code"
            : "Show pairing code",
      ),
    ),
  );
}

window.__HERMES_PLUGINS__.register("alice", ConnectAlice);
