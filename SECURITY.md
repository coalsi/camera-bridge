# Security policy

Camera Bridge handles camera credentials, a HomeKit pairing identity and live video of people's homes, so security reports
are taken seriously.

## Reporting a vulnerability

**Use GitHub's private report:** [Report a vulnerability](https://github.com/coalsi/camera-bridge/security/advisories/new)
(the repository's *Security* tab). You can also email <security@camera-bridge.app>. Please do not open a public issue or
pull request for a vulnerability.

Include what you found, the Camera Bridge OS version (the build number on About in the web interface), steps to
reproduce, and what an attacker could do with it. If you need to share sensitive details, say so in a first message and we
will agree on a safe way. Do not include real camera passwords or video of other people.

You can expect an acknowledgement within 5 business days and a first assessment within 14 days. Fixes for confirmed issues
ship in the next Camera Bridge OS beta, which a box installs as a normal update; you will be told when it is out and
credited if you wish. Please give a reasonable period to fix a problem before you publish it. 90 days is a good default.

## Scope

In scope: Camera Bridge OS and the engine in this repository, including the HomeKit Accessory Protocol server (pairing,
sessions, HomeKit Data Stream), the web interface, its sign-in and the Apple TVs' keys, camera credential handling, the local webhook server, the secure address and its certificate handling,
the diagnostics export and redaction, the update mechanism and release signing, and the build scripts.

Out of scope: vulnerabilities in cameras or their firmware, in Apple's Home app, hubs or operating systems, in third-party
dependencies (report those upstream; tell us if Camera Bridge is affected), social engineering, and findings that need a
box or network that is already compromised, or physical access to the box.

## Supported versions

| Version | Supported |
|---|---|
| Camera Bridge OS beta (the latest build) | Yes. Fixes ship in the next beta, which a box installs as an update. |
| Earlier Camera Bridge OS betas | No. Update to the latest. |
| The archived Camera Bridge for Mac app | No. It no longer gets fixes. |

## What Camera Bridge does with secrets

- Camera passwords and the HomeKit pairing keys are kept in the box's encrypted secret store, never in the configuration
  file or logs. Logs and the diagnostics export are redacted (URL user info, password-like parameters).
- An Apple TV, iPhone or iPad is added only when the signed-in owner types the code it shows, and it is handed its key once. The box keeps only the
  SHA-256 of the key (256 random bits), with the device's name, model and when and from where it was last used, so a copy of its files
  signs nobody in; no administrator password is typed into or kept on one. The key only watches (live and recorded video, still
  pictures, events) and moves cameras that pan and tilt: it changes nothing else on the box. It is sent in a header and never in an
  address, it stops working after a year unused, and Remove in Settings stops it at once (a live view it has open ends within 5 seconds).
- For AirPlay and CarPlay the app trades its key for an HLS ticket, which goes in the address of the video it opens
  (`/api/v1/hls/<ticket>/...`). That is a deliberate exception to "no token in an address": a ticket opens one camera, read-only, is random
  (256 bits), lives in memory only, ends 5 minutes after its last use (6 hours at most) and is lost when its device is removed; the key
  itself is never accepted in an address. It is for the home network only for now.
- Camera Bridge OS sends no telemetry. It talks to the cameras on your network and to the paired Home hub, to GitHub to
  check for updates, to a time server for the clock, to a camera maker's cloud only if you add a cloud camera, and to the AI
  service you choose, only for cameras with AI descriptions on, and only still pictures. While the secure address is on (it is
  by default), it also talks to www.camera-bridge.app and Let's Encrypt, see the next item.
- The secure address (`https://<random name>.box.camera-bridge.app`): the box registers once with www.camera-bridge.app, sending its
  public key (the website sees the home's public internet address), tells the website its private home-network address whenever that changes
  (the website publishes it as the public DNS record of the box's name), and asks Let's Encrypt for a certificate, with the website
  answering the DNS challenge. Certificates are listed in public Certificate Transparency logs, so the random name can be found there.
  Video, the web page and passwords never go through the website. Turning off **Use the secure address** on the System page stops
  all of these calls.
- AI descriptions are the one feature that sends pictures from your cameras to a cloud service. They are off until you choose
  a service in Settings, save your own key for it (a model at home may need none) and switch AI descriptions on for a camera. Then each event on that camera
  sends at most 5 small still pictures from around it (JPEGs up to 768 pixels wide), the camera's name, the kind of event and
  the time to that service: no video and no sound, nothing from a camera whose switch is off, and no pictures kept on the box
  afterwards. What the service does with them is governed by its own terms. The one exception is the Try it button in Settings, which sends the pictures of a camera you choose, at that
  moment, whatever its switch says. The service can be a model on your own network (an address such as
  `http://192.168.77.10:11434/v1`), which keeps the pictures at home; an `http://` address is not encrypted, so use it only
  for such a model. Events are described one at a time, at most one per camera per minute and 200 a day (a limit you can change).
  The box never follows a redirect from the service: the key and the pictures go to the address you saved and to no other, so a
  service (or a typo, or a captive portal) that answers with a redirect is reported as a problem and nothing is sent on. The camera's
  switch and the service are checked again right before each send, the one retry included: turn the switch off, choose Off or change
  the service while a description is on its way, and nothing more is sent for it. While a camera's switch is on and the service is not on
  your home network, the camera's Security card says where its event pictures go; its badge is about the camera's own traffic.
- The AI service's key is kept in the same encrypted secret store, never in the configuration file or logs. It is write-only:
  the web page can save or remove it but never gets it back, only its last four characters. Changing the service, or the
  server of an OpenAI-compatible address, deletes the saved key, so a key is never sent to a service it was not made for.
- Releases are signed, and a box verifies the signature and every file before it installs an update. A new version that
  does not start properly is rolled back automatically.
