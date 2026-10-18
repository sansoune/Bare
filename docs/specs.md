# Bare: Product Spec (v0.1)

## 1. Vision
 
A phone designed from the ground up, hardware and software, for one owner first and for anyone who wants to build it second. It keeps what makes the iPhone great (smoothness, polish, fewer steps per task) and removes what makes it closed (no sideloading, locked defaults, no real file or system access).
 
**Principles**
 
1. **Feel first.** Every animation is smooth, deliberate, and on time. Smoothness is measured, not felt.
2. **Fewer steps.** Any common task takes the minimum number of interactions.
3. **Freedom with security.** The owner controls the device fully, and the device protects the owner by default.
4. **On demand.** Every power-hungry component wakes when needed and sleeps otherwise.
5. **Open.** Hardware notes, software, and protocols are documented so anyone can build, change, and extend it.

## 2. Measurable targets
 
| Area | Target | Notes |
|---|---|---|
| Frame pacing | 99% of frames under 8.3 ms at 120 Hz | Measured with an automated harness from day one |
| Touch-to-pixel latency | under 50 ms , stretch 30 ms | Touch sampling at 240 Hz or higher |
| Refresh rate | 120 Hz minimum, adaptive 1-120 Hz (LTPO) | Higher only if power allows |
| Battery | a full day of heavy use , stretch 2 days | Largest cell the body allows |
| Skin temperature, normal use | no perceptible warmth, 35°C or lower | Hand is about 33°C |
| Skin temperature, heavy load | 38°C or lower, graceful slowdown, no hot spots | Vapor chamber plus metal frame |
| Face unlock | under 500 ms, false accept 1 in 1,000,000 or better  | PIN as fallback |
| Display | about 6.3", about 2622 x 1206, final resolution follows the chosen panel | 1.5K LTPO OLED class |
| Wireless | Wi-Fi 6E or newer, fast cellular | |

## 3. Tier 1: Now (software, built on QEMU and a dev board)

### Feel
- Compositor locked to the display refresh rate, with no dropped frames
- Spring-based animation system with gesture continuity (gestures can be interrupted and redirected mid-motion)
- Consistent design language across the shell and first-party apps
- **Haptic language:** haptics designed together with animations (taps, swipes, toggles, confirmations), not added afterward

### Speed of use
- Rule: every common task takes 2 interactions or fewer where possible
- Modes, routines, and shortcuts with more freedom than iOS Shortcuts or Samsung Modes: user-defined triggers, conditions, and actions, scriptable
- Quick actions reachable from anywhere in the shell
- Smart home control at the minimum number of steps (for example one gesture or tile per device or scene), using open standards such as Matter

### System
- Multitasking with a fast, predictable app switcher
- **Per-app audio routing:** play music to a Bluetooth speaker while the phone's other audio stays on the phone
- Local AI runtime that wakes the accelerator on demand and sleeps it otherwise
- Open sensor API (accelerometer, gyroscope, magnetometer, orientation, barometer, light, proximity, and others) so developers can build new use cases


### Apps and compatibility
- **Native SDK** for first-party and third-party apps
- **PWA runtime** with an app-like wrapper
- **Android compatibility layer** (container-based)
- First-party apps for daily use: phone, messages, browser, camera, notes, files, settings

### Connectivity with other ecosystems
- **PC link:** two-way clipboard, file sharing, and notifications, based on the open KDE Connect protocol
- **Nearby sharing with other phones:** interoperability with AirDrop and Quick Share (depends on Wi-Fi chipset support, so it is a hardware selection criterion)

### Security (software)
- Secure boot and verified boot, with a **user-controlled bootloader that can be re-locked**
- Per-app sandboxing and a permission system the owner fully controls
- Encrypted storage, with keys held in hardware (see Tier 2)
- Face unlock restricted to the owner (liveness and attention checks), PIN as fallback

## 4. Tier 2: Hardware stage (after the software is daily-drivable)
 
- **SoC module:** efficient first, fast second; strong NPU for local models; good Linux mainline support
- **Display:** about 6.3" LTPO OLED, 120 Hz or higher, 240 Hz or higher touch sampling. Pick the panel first, then fit the resolution to it.
- **Battery:** silicon-carbon cell sized to the body, **user-replaceable**, with a safe battery management system and a fuel gauge
- **Thermals:** vapor chamber, graphite spreading, metal frame. The goal is even heat spread and low power draw, not just cooling
- **Face unlock:** cutout (island-style) housing the IR camera, flood illuminator, and dot projector. Under-display IR is a later upgrade if a viable part exists. Optional under-display ultrasonic fingerprint sensor as a backup
- **Camera:** 1-inch-class main sensor with high dynamic range and a clean RAW/log pipeline, tuned for log capture and color grading with a predefined look. Ultrawide and 3-5x telephoto added after the main camera is excellent
- **Haptics:** a large, high-quality linear actuator (a major part of the premium feel)
- **Security hardware:** secure element or TEE for keys, **hardware kill switches** for microphone, camera, and radios
- **Connectivity:** USB-C, dual SIM and eSIM, UWB, NFC (tags, transit, keys), Wi-Fi 6E or newer, Bluetooth, fast cellular
- **Repairability:** modular parts where possible, documented teardown and repair guide

## 5. Tier 3: Later and research (deliberately cut for now)
 
- Contactless payments (needs secure-element provisioning and bank/network agreements, not just a protocol)
- Dedicated communication chip with a custom protocol (more realistic as software on top of existing BLE/UWB/LoRa radios)
- Dedicated mesh network between phones (more realistic as an offline messaging app over BLE or LoRa)
These return to the plan once Tiers 1 and 2 are working.

## 6. Development approach
 
- Develop the OS and shell on **QEMU (aarch64 `virt`)** on the laptop, in a phone-sized window with simulated touch
- Write hardware specs from **real datasheets**, not invented ones
- Get **one cheap real board early** (RK3588 or Raspberry Pi with touchscreen) and test on it every few weeks
- Keep everything in one monorepo with a reproducible dev environment
- Record every major choice in `docs/decisions/` as a short numbered note


## 7. Milestones
 
| # | Milestone | Done when |
|---|---|---|
| M0 | Repo and docs | Monorepo, `README.md`, this spec, ... |
| M1 | Boots in QEMU | Minimal system boots to a graphical window |
| M2 | One perfect gesture | Swipe-up-to-home with spring physics hits the frame-pacing target |
| M3 | Shell prototype | Home screen, app switcher, quick actions, haptic hooks on the dev board |
| M4 | Daily-usable core | First-party apps plus PWA runtime, and used daily on a test device |
| M5 | Compatibility | Android apps run through the compatibility layer |
| M6 | PC link and nearby sharing | KDE Connect-based PC link and AirDrop/Quick Share interop working |
| M7 | Hardware selection | Panel, SoC module, battery, and camera sensor chosen from real datasheets |


