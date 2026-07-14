# Changelog

All notable changes to KDB (Kindle Dashboard) are documented here.

## [v1.06] — 2026-07-14

### 🤖 Auto-generated from git commits
- Fix: Replace _last_full_h with _long_done edge-trigger to fix cross-day update bug
- Refactor: Zero-state daily refresh logic
- docs: add CHANGELOG.md with full version history

---

---

## [v1.05] — 2026-07-07

### 🔧 Fixed
- **RTC spam loop**: `try_rtc_time_sync()` was calling `hwclock -w` every 60 seconds on devices with dead RTC batteries, flooding the log with ~1440 identical lines/day and wasting CPU. Now probed **once at startup** — if the RTC battery is dead, all `hwclock` writes are permanently disabled for the session.
- **Stuck in offline mode**: After Suspend-to-RAM corrupted the system clock back to epoch (1970), `needs_full_refresh()` would never trigger because the local hour was garbage. Added a year < 2020 safety check that forces a network refresh cycle to re-sync time.
- **Weather description overflow**: Long descriptions like "Patchy rain nearby" would bleed into adjacent UI panels. `shorten_desc()` now applies to **all** weather text (current + forecasts) and covers more keywords: patchy, fog, mist, haze, clear, sunny, ice, sleet, hail, blizzard.

---

## [v1.04] — 2026-07-06

### 🚨 Critical Fix
- **Clock reset after STR**: On devices with dead RTC batteries, waking from Suspend-to-RAM would reset the system clock to 1970-01-01 00:00. The display would show `00:xx` instead of the correct time.
  - Pre-flight RTC check before entering STR; falls back to software sleep if RTC is dead.
  - Time checkpoint saved to `/tmp` before STR; restored on resume if kernel clock was corrupted.

### ✨ New
- **WiFi Takeover Module** (`net_manager.lua`): All networking hack logic extracted from `main.lua` into a standalone, reusable module.
  - `NetManager.connect(config)` — wifid freeze + wpa_cli injection + DHCP/DNS
  - `NetManager.disconnect()` — cleanup bind mounts + unfreeze wifid
  - `NetManager.fetch_weather()` — wttr.in with direct IPv4 fallback

### 📖 Docs
- README: Added **⚠️ Advanced Wi-Fi Takeover (K4NT)** section documenting the 5-step network injection process.

---

## [v1.03] — 2026-07-05

### ✨ New
- **Native wifid bypass**: Freeze `wifid` with `killall -STOP` to prevent Dev Key revocation, then drive `wpa_supplicant` directly via `wpa_cli`.
- **Dynamic DNS injection**: Construct custom `resolv.conf` in `/tmp` and inject it via `mount -o bind` over the read-only `/etc/resolv.conf`.
- **DHCP & gateway fallback**: If `udhcpc` fails, mathematically derive and inject a default gateway via `route add`.
- **Direct IPv4 bypass**: When DNS resolution times out, fall back to a direct IPv4 request to `wttr.in` (5.9.243.187) with proper `Host` header.

---

## [v1.02] — 2026-05-08

### 🔧 Fixed
- **The 11-Minute Curse**: Display would freeze exactly 11 minutes after launch due to a `powerd` screensaver timeout reclaiming the framebuffer.

---

## [v1.01] — 2026-05-07

### 🔧 Fixed
- **Bare-metal RTC wakeup**: Hardware RTC alarm for night-stealth sleep mode.
- **Input storm hotfixes**: Prevent spurious input events from waking the device repeatedly.

---

## [v1.0] — 2026-05-06

### 🎉 Initial Release
- E-ink weather dashboard for jailbroken Kindle 4 NT.
- SVG rendering pipeline with NanoSVG + fbink.
- Calendar, memo pad, battery indicator.
- Night stealth mode (02:00–04:59) with Suspend-to-RAM.
- Bilingual i18n support (zh/en).
