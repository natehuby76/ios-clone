import SwiftUI
import MapKit
import QuartzCore

@MainActor
struct CommaFollowingMap: UIViewRepresentable {
    @ObservedObject var navigation: NavigationModel
    var bottomInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(navigation: navigation) }
    func makeUIView(context: Context) -> FollowingMapView {
        let map = FollowingMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.showsCompass = false
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        map.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layoutChanged() }
        context.coordinator.map = map
        return map
    }
    func updateUIView(_ map: FollowingMapView, context: Context) {
        context.coordinator.update(bottomInset: bottomInset)
    }
    static func dismantleUIView(_ map: FollowingMapView, coordinator: Coordinator) {
        coordinator.stop()
        map.onLayout = nil
        map.delegate = nil
    }

    final class FollowingMapView: MKMapView {
        var onLayout: (() -> Void)?
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != previousSize {
                previousSize = bounds.size
                onLayout?()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let navigation: NavigationModel
        weak var map: FollowingMapView?
        private let marker = MKPointAnnotation()
        private let destination = MKPointAnnotation()
        private var markerAdded = false
        private var destinationAdded = false
        private var line: MKPolyline?
        private var displayLink: CADisplayLink?
        private var displayed: RoutePoint?
        private var origin: RoutePoint?
        private var target: RoutePoint?
        private var heading = 0.0
        private var originHeading = 0.0
        private var targetHeading = 0.0
        private var startedAt: CFTimeInterval = 0
        private var duration = 0.0
        private var lastArrival: CFTimeInterval?
        private var acceptedDate = Date.distantPast
        private var bottomInset: CGFloat = 0
        private var distance = 2800.0
        private var targetDistance = 2800.0
        private var originDistance = 2800.0
        private var framed = false
        private var changingCamera = false
        private var overviewRevision = -1
        private var wasFollowing = false
        private lazy var markerImage: UIImage = {
            UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 40, height: 40))
                StarPilotTheme.uiAccent.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 3, y: 3, width: 34, height: 34))
                let arrow = UIBezierPath()
                arrow.move(to: CGPoint(x: 20, y: 8))
                arrow.addLine(to: CGPoint(x: 30, y: 30))
                arrow.addLine(to: CGPoint(x: 20, y: 25))
                arrow.addLine(to: CGPoint(x: 10, y: 30))
                arrow.close()
                UIColor.white.setFill()
                arrow.fill()
            }
        }()

        init(navigation: NavigationModel) {
            self.navigation = navigation
            self.overviewRevision = navigation.overviewRevision
        }

        func update(bottomInset: CGFloat) {
            guard let map else { return }
            let insetChanged = self.bottomInset != bottomInset
            self.bottomInset = bottomInset
            if line !== navigation.commaPolyline {
                if let line { map.removeOverlay(line) }
                line = navigation.commaPolyline
                if let line { map.addOverlay(line) }
            }
            if let place = navigation.destination {
                destination.coordinate = place.coordinate
                destination.title = place.name
                if !destinationAdded { map.addAnnotation(destination); destinationAdded = true }
            } else if destinationAdded {
                map.removeAnnotation(destination); destinationAdded = false
            }
            let recenter = navigation.followsUser && !wasFollowing
            wasFollowing = navigation.followsUser
            if !navigation.followsUser, navigation.overviewRevision != overviewRevision, let line {
                overviewRevision = navigation.overviewRevision
                changingCamera = true
                map.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(
                    top: 220, left: 40, bottom: bottomInset + 40, right: 60), animated: !UIAccessibility.isReduceMotionEnabled)
                changingCamera = false
            }
            guard navigation.commaFeedReady, let coordinate = navigation.commaPosition,
                  Date().timeIntervalSince(navigation.commaPositionSampleDate) <= 4 else {
                stop()
                if markerAdded { map.removeAnnotation(marker); markerAdded = false }
                displayed = nil; target = nil; lastArrival = nil; framed = false
                return
            }
            let received = navigation.commaPositionSampleDate
            if received != acceptedDate {
                let now = CACurrentMediaTime()
                let point = RoutePoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let elapsed = lastArrival.map { now - $0 } ?? 0
                if let previous = target, elapsed > 0, elapsed < 5 {
                    let meters = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                        .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                    targetDistance = NavigationMapMotion.cameraDistance(speed: meters / elapsed,
                        distanceToTurn: navigation.distanceToTurn)
                }
                origin = displayed ?? point; target = point
                originHeading = heading
                targetHeading = NavigationMapMotion.heading(from: heading, to: navigation.commaHeading, fraction: 1)
                originDistance = distance
                let jump = displayed.map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                        .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                } ?? 0
                if jump > 500 { framed = false }
                duration = displayed == nil || jump > 500 || UIAccessibility.isReduceMotionEnabled ? 0 : min(2.5, max(0.35, elapsed))
                acceptedDate = received; lastArrival = now; startedAt = now
                if !markerAdded { marker.coordinate = coordinate; map.addAnnotation(marker); markerAdded = true }
                render(at: now)
                if duration > 0 { start() }
            } else if recenter || insetChanged { render(at: CACurrentMediaTime()) }
        }
        private func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        func stop() { displayLink?.invalidate(); displayLink = nil }
        @objc private func frame(_ link: CADisplayLink) {
            guard navigation.commaFeedReady, Date().timeIntervalSince(acceptedDate) <= 4 else {
                if let map, markerAdded { map.removeAnnotation(marker); markerAdded = false }
                stop()
                return
            }
            render(at: link.timestamp)
            if duration == 0 || link.timestamp - startedAt >= duration { stop() }
        }
        func layoutChanged() { render(at: CACurrentMediaTime()) }
        private func render(at time: CFTimeInterval) {
            guard let map, let origin, let target, map.bounds.width > 0, map.bounds.height > 0,
                  navigation.commaFeedReady, Date().timeIntervalSince(acceptedDate) <= 4 else { return }
            let fraction = duration > 0 ? min(1, max(0, (time - startedAt) / duration)) : 1
            let point = NavigationMapMotion.point(from: origin, to: target, fraction: fraction)
            displayed = point
            heading = NavigationMapMotion.heading(from: originHeading, to: targetHeading, fraction: fraction)
            distance = originDistance + (targetDistance - originDistance) * fraction
            let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            marker.coordinate = coordinate
            if navigation.followsUser {
                changingCamera = true
                let center = framed ? map.camera.centerCoordinate : coordinate
                map.setCamera(MKMapCamera(lookingAtCenter: center, fromDistance: distance, pitch: 40, heading: heading), animated: false)
                let anchor = CGPoint(x: map.bounds.midX, y: CGFloat(NavigationMapMotion.anchorY(
                    height: Double(map.bounds.height), bottomInset: Double(bottomInset))))
                for _ in 0..<(framed ? 1 : 3) {
                    let screen = map.convert(coordinate, toPointTo: map)
                    let centerPoint = CGPoint(x: map.bounds.midX + screen.x - anchor.x,
                        y: map.bounds.midY + screen.y - anchor.y)
                    let shifted = map.convert(centerPoint, toCoordinateFrom: map)
                    if CLLocationCoordinate2DIsValid(shifted) { map.setCenter(shifted, animated: false) }
                }
                framed = true
                changingCamera = false
            }
            if let view = map.view(for: marker) {
                view.transform = CGAffineTransform(rotationAngle: (heading - map.camera.heading) * .pi / 180)
            }
        }
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard !changingCamera, hasGesture(in: mapView) else { return }
            navigation.followsUser = false
        }
        private func hasGesture(in view: UIView) -> Bool {
            (view.gestureRecognizers ?? []).contains { $0.state == .began || $0.state == .changed } ||
                view.subviews.contains { hasGesture(in: $0) }
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation === marker else { return nil }
            let id = "comma-navigation-position"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ??
                MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation; view.image = markerImage
            view.displayPriority = .required
            view.collisionMode = .circle
            view.canShowCallout = false
            view.isAccessibilityElement = true
            view.accessibilityLabel = "Comma location"
            view.accessibilityIdentifier = "comma-navigation-marker"
            return view
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = StarPilotTheme.uiAccent; renderer.lineWidth = 7
            renderer.lineCap = .round; renderer.lineJoin = .round
            return renderer
        }
    }
}
