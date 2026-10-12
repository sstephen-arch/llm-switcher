# LLM Switcher: pairing, other computers, and phone access

Status: design, 10 Oct 2026. Nothing here is built yet.

## Goals

1. Connecting another computer must be "install, approve on the Mac, done". Today it is copying a
   URL, a key and sometimes a certificate by hand, then editing each tool's config.
2. Use your models from your iPhone like ChatGPT, at home and away, with no VPN app.
3. Privacy is the product: conversations are encrypted from the device to your Mac, and when the
   network allows, nothing sits in between at all.

## Pairing and connection principles

| Principle | What it means here |
|---|---|
| Discover-and-approve beats pasting addresses and tokens | Devices find the Mac over Bonjour (`_claudelocal._tcp`) or by a short code; the Mac shows "X wants to connect, code 482 913, Approve?" and issues that device its own `ShareClient` key |
| **A random approval code authenticates nothing**: a man-in-the-middle can relay it, both screens agree, and the device ends up trusting the relay | The code is derived from the certificate each side actually sees (short authentication string, like Bluetooth numeric comparison). Never a random number the server reports |
| Pinning is the point, not TLS | TLS on by default. The pairing reply carries the certificate's SHA-256 and the device pins it. No "install this certificate into your system" step |
| First contact is the only unpinned hop | Only discovery/health/pair travel before the pin. A device that is paired but holds no pin is refused, never let through |
| Pin the handshake that carried the approval | Never pin a fingerprint read back from a later request; that pins whoever answers it |
| iOS drops sockets when the screen locks | Long work is start-then-collect: the Mac keeps generating and holds the finished reply for minutes; the phone collects it by id |
| An in-memory queue is lost when iOS kills the app | Outgoing messages and pending replies live on disk (a small state machine, state written before each attempt) |
| `NSBonjourServices` is generated from `project.yml` | Declare `_claudelocal._tcp` in the iOS `project.yml`, never the plist. An undeclared type returns "nothing found", not an error |
| macOS ignores `kSecAttrLabel` on certificates | Find keychain identities by the private key's `kSecAttrApplicationTag` |
| Errors need words | Every connection failure carries a sentence, not a bare error code |
| Green tests and a simulator run are not verification | Prove each screen is reachable on a real iPhone first, then iterate on behaviour |

## Other computers: the "Connect" helper

Third-party tools (OpenCode, Claude Code, Codex, VS Code, Cline) cannot pin a certificate; they
want a trusted CA or plain HTTP. So a small helper app (Windows tray + Mac menu bar):

1. Pairs with the Mac using the ceremony above and pins its certificate.
2. Runs a local proxy on `127.0.0.1` on that computer. Tools talk plain HTTP to localhost; the
   helper forwards over the pinned, encrypted connection.
3. Writes each tool's config for you (OpenCode `opencode.json`, Claude Code env, Codex
   `config.toml`, VS Code/Cline/Continue settings, Xcode "Locally Hosted" provider on Macs).

## Phone away from home: direct first, encrypted relay as fallback

### Direct (preferred: no third party at all)

- **Mutual TLS.** Each paired device gets a client certificate at pairing. Anything without one,
  for example internet scanners, cannot complete the handshake, so the open port reveals nothing.
- **IPv6 first.** Most mobile carriers and many home ISPs give global IPv6; with it there is no NAT,
  only the router's firewall to open.
- **Automatic port opening** via NAT-PMP / PCP (Apple's `DNSServiceNATPortMappingCreate`) and
  UPnP-IGD. Fall back to guiding a one-time manual port forward.
- **Finding the Mac when its address changes:** the Mac writes its current address to the user's
  own iCloud (CloudKit private database, `encryptedValues`). Apple stores an encrypted address in
  the user's own account; no messages, no data.
- **Mac must be awake** while sharing (offer "prevent sleep while sharing").

### Relay (only when direct is impossible)

Carrier-grade NAT (T-Mobile/Verizon 5G home internet, Starlink and others) makes inbound
connections impossible. Then both Mac and phone connect *out* to a small relay that forwards sealed
bytes (pattern: iTerm2's companion relay). End-to-end encryption plus the certificate-derived
pairing code means the relay can neither read nor impersonate. It still sees that a connection
happened, when, and roughly how much; direct removes even that. The relay could be self-hosted.

The app always shows which path is in use: "Connected directly to your Mac" or "Connected through
the encrypted relay".

## Build order

1. Pairing on the Mac: approve prompt, certificate-derived code, per-device keys, TLS on by
   default, pinning; mutual TLS for remote devices.
2. Connect helper for other computers: pairing, localhost proxy, automatic tool configuration.
3. iPhone app on the home network: pairing, chat, camera to vision models, persisted queue,
   start-then-collect replies.
4. Away from home: direct path (IPv6, port opening, iCloud address), then the encrypted relay
   fallback.

Each step gets an adversarial review before it ships: in pairing, the shortcuts that make the
ceremony convenient are exactly where it tends to become exploitable.
