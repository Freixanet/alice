import AVFoundation
import SwiftUI
import VisionKit

/// The in-app QR scanner behind Connect → Scan QR. The iPhone's own Camera
/// app also pairs — the `alice://` scheme opens Alice directly — but this
/// one saves leaving the app. Every state it can be in keeps a paste field,
/// because a camera cannot always help: simulator, denied permission, or the
/// code arriving as text instead of ink.
///
/// Self-contained on purpose: a recognised QR — scanned or pasted — turns
/// the sheet into the pairing confirmation in place, so the caller presents
/// one sheet and nothing races SwiftUI's single-sheet rule.
struct PairingScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var camera: CameraState = .resolving
    @State private var scannedLink: String?
    @State private var pasted = ""

    enum CameraState {
        case resolving
        case ready
        case denied
        case unsupported
        case unavailable
    }

    var body: some View {
        NavigationStack {
            contents
                .navigationTitle(scannedLink == nil ? "Scan QR" : "Pair")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    // Once a code is chosen the sheet has become the pairing
                    // form. Keeping a second link field under that form made it
                    // look as though another code was still required.
                    if scannedLink == nil { pasteField }
                }
        }
        .task { await resolveCamera() }
    }

    /// Once a QR is read the sheet turns into the pairing confirmation in
    /// place — presenting one sheet from inside another races SwiftUI's
    /// single-sheet rule, and this needs no second presentation at all.
    @ViewBuilder
    private var contents: some View {
        if let scannedLink {
            PairingForm(link: scannedLink, onDone: { dismiss() })
        } else {
            switch camera {
            case .resolving:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                QRScannerView(
                    onFound: { text in scannedLink = text },
                    onUnavailable: { camera = .unavailable }
                )
                // UIViewControllerRepresentable has no intrinsic size. Give
                // the scanner the whole sheet explicitly; otherwise SwiftUI
                // may lay the controller out at effectively zero height while
                // leaving the navigation chrome visible.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea(edges: .bottom)
            case .denied:
                MessageView(
                    "Alice needs camera access to scan the pairing QR. Allow it in Settings, or paste the pairing link below."
                )
            case .unsupported:
                MessageView(
                    "This device does not support the built-in scanner. Paste the pairing link below, or scan it with the Camera app."
                )
            case .unavailable:
                MessageView(
                    "The camera scanner is unavailable right now. Paste the pairing link below or try again later."
                )
            }
        }
    }

    private var pasteField: some View {
        HStack(spacing: 12) {
            TextField("Or paste the pairing link", text: $pasted)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Use link") {
                scannedLink = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                pasted = ""
            }
            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func resolveCamera() async {
        guard DataScannerViewController.isSupported else {
            camera = .unsupported
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera = DataScannerViewController.isAvailable ? .ready : .unavailable
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            if granted {
                camera = DataScannerViewController.isAvailable ? .ready : .unavailable
            } else {
                camera = .denied
            }
        case .denied, .restricted:
            camera = .denied
        @unknown default:
            camera = .unavailable
        }
    }
}

/// The live camera view. Kept private: pairing is its only user.
private struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFound: onFound, onUnavailable: onUnavailable)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        // DataScannerViewController is not open, so it cannot be subclassed
        // to auto-start; a plain container does that the moment it appears.
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isPinchToZoomEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return ScannerContainer(
            scanner: scanner,
            onStartFailure: context.coordinator.reportUnavailable
        )
    }

    func updateUIViewController(_ container: UIViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: UIViewController,
        coordinator: Coordinator
    ) {
        (uiViewController as? ScannerContainer)?.stop()
    }

    /// Hosts the VisionKit scanner as a real child controller and pins its
    /// preview to every edge. The old 1×1 bootstrap frame relied on autoresizing
    /// to expand later, which can leave the camera running inside an invisible
    /// one-pixel view when SwiftUI presents this controller in a sheet.
    private final class ScannerContainer: UIViewController {
        private let scanner: DataScannerViewController
        private let onStartFailure: () -> Void

        init(scanner: DataScannerViewController, onStartFailure: @escaping () -> Void) {
            self.scanner = scanner
            self.onStartFailure = onStartFailure
            super.init(nibName: nil, bundle: nil)

            view.backgroundColor = .black
            addChild(scanner)
            scanner.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scanner.view)
            NSLayoutConstraint.activate([
                scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
                scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            scanner.didMove(toParent: self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Pairing scanner is built in code.")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            do {
                try scanner.startScanning()
            } catch {
                onStartFailure()
            }
        }

        func stop() {
            scanner.stopScanning()
        }
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void
        private let onUnavailable: () -> Void
        private var reported = false

        init(onFound: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onFound = onFound
            self.onUnavailable = onUnavailable
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !reported else { return }
            for case let .barcode(barcode) in addedItems {
                guard let text = barcode.payloadStringValue else { continue }
                reported = true
                dataScanner.stopScanning()
                onFound(text)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            reportUnavailable()
        }

        func reportUnavailable() {
            guard !reported else { return }
            reported = true
            onUnavailable()
        }
    }
}

/// A one-line explanation where a camera view would have been.
private struct MessageView: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        ContentUnavailableView {
            Label("No scanner", systemImage: "qrcode.viewfinder")
        } description: {
            Text(text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
