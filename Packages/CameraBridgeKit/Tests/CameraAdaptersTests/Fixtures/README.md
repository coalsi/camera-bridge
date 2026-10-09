# CameraAdapters test fixtures

Synthetic camera API responses written for these tests from the public formats
(ONVIF Core/Media/Events/DeviceIO specs, Hikvision ISAPI examples, Reolink HTTP API v8), with Scrypted's plugin
parsers read for behaviour only. Not captured from real devices; addresses are loopback or documentation ranges; no real
credentials. Tests read them via `#filePath` (no SwiftPM resources).

`amcrest/`, `doorbird/`, `unifi/` (2026-10-08): payloads written for these tests from the vendors' public descriptions: Dahua's event stream as documented by
the MIT-licensed `rroller/dahua` and Home Assistant's docs, DoorBird's LAN API revision 0.36, Ubiquiti's published Protect Integration API description. Not
captured from real devices; documentation addresses and made-up identifiers only. (No Scrypted plug-in code and no GPL python-amcrest code was used.)
