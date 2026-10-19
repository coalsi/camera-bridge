# Camera DNS (easier by hand, more often automatic) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** More cameras get their DNS pointed at Camera Bridge by "Set up for Camera Bridge", and where it can't, the person gets exact,
camera-specific steps with a link to the camera's page and the values to copy.

**Architecture:** Changes stay in the existing DNS paths (`CameraSettingsService+DNS.swift` and the vendor files), the setup step
model (one new opt-in choice), the manual-help table (`CameraManualHelp.swift`, now fed with the camera's current network facts) and
the page's help block (`manual-help.js`). No new screens.

**Tech Stack:** Swift 6.4 / Swift Testing (Packages/CameraBridgeKit), vanilla JS (`linux/web`), Node test runner (`linux/web-tests`).

**Spec:** `docs/superpowers/specs/2026-10-18-camera-dns-design.md`. Research: `.superpowers/sdd/camera-dns-research.md` (per-maker paths
and confidence, §4; vendor APIs, §2). Audit of today's code: `.superpowers/sdd/camera-dns-audit.md`.

## Global Constraints

- Never change a camera's address. The fixed-address choice keeps the camera's own address, mask and gateway exactly, and is off by
  default; Restore puts DHCP back.
- Never restart a camera unless the person presses **Restart the camera now**.
- Every new camera call goes through the existing login guards (`ONVIFLoginGuard`, the vendor clients' digest handling); no new way
  to lock an account out.
- DNS values: Camera Bridge's address in both slots; never a public server, never empty unless the camera refuses the same address twice.
- After a write, read back every 2 s for up to 30 s (`DNSReadBackTiming`) before deciding, on every path.
- Menu paths come from the research's §4 table; a path marked best guess shows "Menu names differ between models and firmware versions,
  so look for the closest match."
- Exact copy: button **Open the camera's web page**; button **Copy**; setup choice **Fix its address so the DNS stays (keeps <address>)**;
  button **Restart the camera now**; evidence line "No lookups seen yet; Camera Bridge can't rule out a built-in DNS server."
- Tests and docs use 192.168.77.x / 192.0.2.x addresses and made-up hardware addresses (02:00:00:00:00:xx).
- Swift: `swift test --filter <Suite>` in `Packages/CameraBridgeKit`; Linux: `sh Tools/linux-test.sh test --filter <Suite>` (shared
  build volume with other worktrees: waiting on the SwiftPM lock is expected); web: `sh linux/web-tests/run.sh`. No publishing.

## Review Focus

1. **A camera that applies DNS slowly or after its network restarts.** The first read-back still shows the old servers: the write must
   not be called refused before 30 s. Test in Task 1 (`aSlowCameraIsGivenThirtySeconds`).
2. **A fixed-address choice on a camera whose current address the bridge doesn't know exactly** (no mask or gateway in the reading):
   the choice is not offered, rather than guessed. Test in Task 4 (`theChoiceNeedsTheWholeAddress`).
3. **Restore after the fixed-address choice** must bring DHCP back even if the camera's DNS was changed by hand since. Test in Task 4
   (`restorePutsDHCPBack`).
4. **A Dahua/Amcrest camera that answers the CGI with HTML or a login page** (not Dahua firmware): fall back to ONVIF, no refusal.
   Test in Task 2 (`aNonDahuaAnswerFallsBackToONVIF`).
5. **Help for a camera with no web page or an unknown maker:** no dead link, the generic path, still the values and copy buttons. Test in
   Task 5 (`anUnknownCameraGetsTheGenericHelpWithoutALink`).

---

### Task 1: ONVIF: both slots first, and patience

**Files:** Modify `Packages/CameraBridgeKit/Sources/CameraAdapters/ONVIF/CameraSettingsService+DNS.swift` (`writeONVIFBridge` ~:246-265);
Test `Packages/CameraBridgeKit/Tests/CameraAdaptersTests/CameraDNSTests.swift` (with `Support/MockONVIFCamera.swift`).

**Interfaces:** Produces the new attempt order `[bridge, bridge]`, `[bridge]`, `[bridge, ""]` and a read-back that polls GetDNS with
`DNSReadBackTiming` (2 s, 30 s) after each write before moving to the next form.

- [ ] **Step 1: Failing tests** — `theFirstFormFillsBothSlots` (the mock records the first SetDNS with two DNSManual entries equal to the
  bridge); `aSlowCameraIsGivenThirtySeconds` (the mock applies the write after 10 s of fake time: success, no second form sent);
  `aCameraThatRefusesTheSameAddressTwiceGetsTheNextForm` (fault on two entries → `[bridge]` sent).
- [ ] **Step 2:** `swift test --filter CameraDNSTests` → FAIL.
- [ ] **Step 3:** Implement with the existing injectable timing (the Reolink/IPC paths' read-back helper).
- [ ] **Step 4:** `swift test --filter "CameraDNSTests|InternetWatchStepTests"` → PASS.
- [ ] **Step 5:** Commit "Camera DNS: Camera Bridge in both slots first, and 30 s for slow cameras (ONVIF)".

---

### Task 2: Dahua, Amcrest, Lorex through their own API

**Files:** Create `Packages/CameraBridgeKit/Sources/CameraAdapters/Amcrest/AmcrestDNS.swift`; Modify `CameraSettingsService+DNS.swift`
(readDNS/applyDNS/restoreDNS branches for `.amcrest`), `CameraDNSBackup` (a `dahuaCGI` method); Test
`Packages/CameraBridgeKit/Tests/CameraAdaptersTests/AmcrestDNSTests.swift`.

**Interfaces:** `AmcrestAPI.networkDNS() async throws -> (interface: String, servers: [String])?` (GET
`/cgi-bin/configManager.cgi?action=getConfig&name=Network`; `table.Network.DefaultInterface`, `table.Network.<if>.DnsServers[0|1]`;
nil when the answer is not Dahua's `table.` text) and `setNetworkDNS(interface:servers:) async throws` (GET
`…?action=setConfig&Network.<if>.DnsServers[0]=A&Network.<if>.DnsServers[1]=B`, "OK" or a refusal with the camera's words). Order for
`.amcrest`: CGI first, ONVIF when the CGI answer is nil.

- [ ] **Step 1: Failing tests** — `readsTheDefaultInterfacesServers`, `writesBothSlotsAndReadsBack`, `aNonDahuaAnswerFallsBackToONVIF`
  (HTML or 404 → ONVIF path used), `restorePutsTheOldServersBack`, `aRefusalCarriesTheCamerasWords`, `aLoginRefusalIsALoginRefusal`.
- [ ] **Step 2:** `swift test --filter AmcrestDNSTests` → FAIL.
- [ ] **Step 3:** Implement with `AmcrestAPI`'s digest client; values are IPv4 addresses only (percent-encode nothing else).
- [ ] **Step 4:** `swift test --filter "AmcrestDNSTests|CameraDNSTests"` → PASS.
- [ ] **Step 5:** Commit "Camera DNS: Dahua, Amcrest and Lorex through their own API".

---

### Task 3: Hikvision: DHCP honesty, account rights, restart on request

**Files:** Modify `Packages/CameraBridgeKit/Sources/CameraAdapters/Hikvision/HikvisionISAPI+DNS.swift`, `HikvisionISAPI+Setup.swift`,
`CameraSettingsService+DNS.swift`; Modify `Packages/CameraBridgeKit/Sources/BridgeEngine/BridgeEngine+CameraSetup.swift` (a restart action),
`Sources/BridgeWeb/WebApp+Routes.swift` (route), `linux/web/js/screens/camera-setup.js` and `security.js` (the button);
Tests `CameraDNSTests.swift`, `Tests/BridgeEngineTests/CameraSetupWatchRuleTests.swift`, `Tests/BridgeWebTests/…`, `linux/web-tests/camera-setup.test.mjs`.

**Interfaces:** The ISAPI DNS reading sets `fromDHCP = (addressingType == "dynamic")`; on dynamic the DNS write is refused with
"the camera takes its address from DHCP, so its DNS would go back to the router’s at the next renewal: choose “Fix its address so the
DNS stays”, or set it by hand with a fixed address" (and offers Task 4's choice); 403 on any ISAPI write → `CameraAdapterError.notPermitted`;
`BridgeEngine.restartCamera(id: UUID) async throws` (uses the existing `CameraSettingsService.reboot()`), `POST cameras/:id/restart` (204),
shown as **Restart the camera now** only when the last setup or reading said the camera needs a restart.

- [ ] **Step 1: Failing tests** — `aDynamicHikvisionIsNotReportedWatchedOnADNSThatWontLast`, `a403IsNotPermittedNotALoginRefusal`,
  `restartRequiredOffersTheButtonAndTheRoute` (engine + web), `theButtonRestartsOnlyWhenPressed`.
- [ ] **Step 2:** run the named suites → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** run them plus `swift test --filter "CameraAdaptersTests|BridgeEngineTests"` once, `sh linux/web-tests/run.sh` → PASS.
- [ ] **Step 5:** Commit "Camera DNS: Hikvision on DHCP said honestly, account rights, restart on request".

---

### Task 4: "Fix its address so the DNS stays" (opt-in)

**Files:** Modify `ONVIFClient+Network.swift` (`setNetworkInterfaces`), `HikvisionISAPI+DNS.swift`, `IPCWebDNS.swift`,
`CameraSettingsService+DNS.swift` (+ backup), the setup step model and preview (`CameraSettingsService+Setup.swift`,
`BridgeEngine+CameraSetup.swift`), `linux/web/js/screens/camera-setup.js`; Tests in the matching suites and `camera-setup.test.mjs`.

**Interfaces:** A setup option `fixAddress: Bool` (default false) on the Watch step, offered in the preview only when (a) the camera's DNS
needs a fixed address (Hikvision `dynamic`, IP camera web API on DHCP, an ONVIF camera whose reading is FromDHCP=true and that refused
manual DNS) and (b) the reading has the current address, prefix/mask and gateway. Applying it: ISAPI `addressingType=static` with the
same values + DNS; IP camera web API `DHCP=0` with the same values + DNS1/DNS2; ONVIF `SetNetworkInterfaces` (IPv4 Enabled, DHCP false,
Manual = current address/prefix) then `SetNetworkDefaultGateway` unchanged, then SetDNS. The backup records the original addressing;
Restore sets DHCP back (and the DNS as it was). The result shows "Reserve <address> for this camera in your router (its hardware address
is <MAC>)" with the MAC from the reading when known.

- [ ] **Step 1: Failing tests** — `theChoiceIsOfferedOnlyWhereDNSNeedsAFixedAddress`, `theChoiceNeedsTheWholeAddress`,
  `fixingKeepsTheSameAddressMaskAndGateway` (each path), `restorePutsDHCPBack`, `offByDefault`, web: the checkbox and the reservation line.
- [ ] **Step 2:** run them → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** run the suites, `sh Tools/linux-test.sh test --filter "CameraDNSTests|IPCWebDNSTests"`, web tests → PASS.
- [ ] **Step 5:** Commit "Camera DNS: an opt-in fixed address so the DNS stays, with Restore".

---

### Task 5: Clear help by hand, per camera maker

**Files:** Modify `Packages/CameraBridgeKit/Sources/BridgeEngine/Security/CameraManualHelp.swift` (context, families, table, router),
the engine code that builds the help context (current servers, address, mask, gateway, MAC, web page URL), `Sources/BridgeWeb` resource
for manual help (new fields), `linux/web/js/screens/manual-help.js`, `linux/web/style.css`; Tests `CameraManualHelpTests.swift`,
`CameraManualHelp*Tests.swift` (web), `linux/web-tests/manual-help.test.mjs` (fixtures re-derived from the Swift table).

**Interfaces:** The help gains `link: {label, url}` (http(s) to the camera's own address only), `current: [String]` (its DNS servers
now), `keep: {address, mask, gateway}` (static-first families), `reserve: {address, mac}`, `warnings: [String]`; values carry
`copy: true`. Families added: Hikvision (+OEMs), Dahua/Amcrest/Lorex, Axis, Hanwha, Uniview, Foscam, VIGI, XMEye, UniFi standalone,
from vendor or ONVIF manufacturer (case-insensitive contains: "hikvision", "annke", "dahua", "amcrest", "lorex", "axis", "hanwha",
"wisenet", "uniview", "foscam", "vigi", "xiongmai", "ubiquiti"). Router text per the spec. The page renders the link as a button
(`target=_blank`, `rel=noopener noreferrer`), **Copy** buttons (clipboard API, falling back to selecting the text), and the current
servers line "Right now it asks A and B. Change both to C."

- [ ] **Step 1: Failing tests** — per family text and confirmed flags (one test per family); `theHelpLinksTheCamerasOwnPage`;
  `anUnknownCameraGetsTheGenericHelpWithoutALink`; `theHelpSaysWhatToChange` (current servers); `aStaticFirstCameraSaysKeepItsAddress`;
  web: link, copy, current line, nothing becomes markup.
- [ ] **Step 2:** run them → FAIL.
- [ ] **Step 3:** Implement (never a link to anything but the camera's own address).
- [ ] **Step 4:** Swift suites and `sh linux/web-tests/run.sh` → PASS; check the Security card in the browser (`bridge-preview`).
- [ ] **Step 5:** Commit "Camera DNS: clear help by hand, with the camera's page, the values to copy and its maker's menus".

---

### Task 6: Honest evidence, IPv6, docs

**Files:** Modify `Packages/CameraBridgeKit/Sources/BridgeEngine/Security/CameraSecurity.swift` (gold rule), the guard's evidence
(`BridgeEngine+InternetGuard.swift`), ONVIF reading of IPv6 (`GetNetworkInterfaces` IPv6 enabled) → a warning; `docs/linux/USER-GUIDE.md`
(Internet guard section), `docs/CONTRACT_CHANGES.md`, module READMEs, `linux/web/js/release-notes.js` (draft entry).

- [ ] **Step 1: Failing tests** — `quietAloneIsNotGold` (watched, no lookup ever seen → not the top level, the exact line shown);
  `oneLookupSeenThenQuietIsGold`; `ipv6OnAddsTheWarning`.
- [ ] **Step 2–4:** red, implement, green (`swift test --filter "CameraSecurity|InternetGuard"`, all Swift once, web tests).
- [ ] **Step 5:** Commit "Camera DNS: no top level on silence alone, an IPv6 warning, docs".
