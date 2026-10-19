import BridgeEngine
import CameraAdapters
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct CameraInterfaceTests {
    private func camera(_ vendor: CameraVendor, host: String = "192.0.2.5", service: IntegrationService? = nil) -> CameraConfiguration {
        var configuration = CameraConfiguration(name: "Cam", kind: .camera, vendor: vendor, endpoint: CameraEndpoint(host: host), username: "")
        configuration.integration = service.map { IntegrationSettings(service: $0) }
        return configuration
    }

    @Test func onlyNetworkCamerasWithAnInterfaceOfTheirOwnOfferCameraSettings() {
        for vendor in [CameraVendor.hikvision, .reolink, .onvif, .rtsp, .amcrest, .doorbird] {
            #expect(camera(vendor).hasCameraInterface, "\(vendor)")
        }
        for vendor in [CameraVendor.demo, .go2rtc, .unifi] {
            #expect(!camera(vendor).hasCameraInterface, "\(vendor)")
        }
        #expect(Set(CameraVendor.allCases) == [.hikvision, .reolink, .onvif, .rtsp, .demo, .go2rtc, .amcrest, .unifi, .doorbird])
    }

    @Test func aCloudCameraIsShownByItsServiceNotByTheHelpersAddress() {
        #expect(camera(.go2rtc, host: "127.0.0.1", service: .ring).displayAddress == "Ring")
        #expect(camera(.go2rtc, host: "127.0.0.1", service: .nest).displayAddress == "Google Nest")
        #expect(camera(.go2rtc, host: "127.0.0.1").displayAddress == "Cloud camera")
        #expect(camera(.unifi, host: "192.0.2.1").displayAddress == "192.0.2.1")
        #expect(camera(.amcrest).displayAddress == "192.0.2.5")
    }

    @Test func vendorNamesForTheNewTypes() {
        #expect(StatusText.vendor(.amcrest) == "Amcrest / Dahua" && StatusText.vendor(.doorbird) == "DoorBird" && StatusText.vendor(.unifi) == "UniFi Protect")
        #expect(StatusText.vendor(.go2rtc) == "Cloud camera")
    }
}
