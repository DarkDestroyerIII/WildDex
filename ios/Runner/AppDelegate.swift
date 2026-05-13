import CoreLocation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate {
  private var locationManager: CLLocationManager?
  private var pendingLocationResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "wilddex/location",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        if call.method == "getRoundedLocation" {
          self?.getLocation(result: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func getLocation(result: @escaping FlutterResult) {
    guard CLLocationManager.locationServicesEnabled() else {
      result(nil)
      return
    }

    if pendingLocationResult != nil {
      result(nil)
      return
    }

    let manager = locationManager ?? CLLocationManager()
    locationManager = manager
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer

    let status = authorizationStatus(for: manager)
    switch status {
    case .authorizedAlways, .authorizedWhenInUse:
      pendingLocationResult = result
      manager.requestLocation()
    case .notDetermined:
      pendingLocationResult = result
      manager.requestWhenInUseAuthorization()
    case .denied, .restricted:
      result(nil)
    @unknown default:
      result(nil)
    }
  }

  private func authorizationStatus(for manager: CLLocationManager) -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) {
      return manager.authorizationStatus
    }
    return CLLocationManager.authorizationStatus()
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = authorizationStatus(for: manager)
    if status == .authorizedAlways || status == .authorizedWhenInUse {
      manager.requestLocation()
    } else if status == .denied || status == .restricted {
      finishLocation(nil)
    }
  }

  func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    finishLocation(locations.last)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    finishLocation(nil)
  }

  private func finishLocation(_ location: CLLocation?) {
    guard let result = pendingLocationResult else { return }
    pendingLocationResult = nil

    guard let location else {
      result(nil)
      return
    }

    result([
      "latitude": location.coordinate.latitude,
      "longitude": location.coordinate.longitude,
      "accuracyMeters": location.horizontalAccuracy,
    ])
  }
}
