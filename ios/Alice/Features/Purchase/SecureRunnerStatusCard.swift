import SwiftUI

/// Explanation only. No legacy checkout button, biometric approval or PSP call.
struct SecureRunnerStatusCard: View {
    @Environment(\.colorScheme) private var scheme
    let status: SecureRunnerDisplayStatus
    let language: ChatLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(status.title(language), systemImage: status == .confirmed ? "checkmark.shield" : "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text(status.explanation(language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 24))
        .accessibilityIdentifier("secureRunner.status.\(status.rawValue)")
    }
}

/// A separately authenticated Alice account may install this channel in the
/// SwiftUI environment after verifying account, tenant, session and installation.
/// Hermes errands, QR payloads and merchant URLs must never create one.
/// There is deliberately no provider in R02: without an Alice IdP the UI is
/// disconnected. Credentials are ephemeral and must be supplied by that IdP.
@MainActor
@Observable
final class SecureRunnerAuthenticatedChannel {
    let id = UUID()
    let jobID: String
    let tenant: String
    let ownerSession: String
    let account: String
    let installation: String
    private(set) var enrolledKeyVersion: Int?
    private var approvalInFlight = false
    private var enrollmentInFlight = false
    private var cancellationInFlight = false

    private let origin: URL
    private let humanBearer: String
    private let client: SecureRunnerStatusClient

    init(
        trustedAliceOrigin: URL, humanBearer: String,
        jobID: String, tenant: String, ownerSession: String,
        account: String, installation: String,
        enrolledKeyVersion: Int?,
        testProtocolClasses: [AnyClass]? = nil
    ) throws {
        guard !jobID.isEmpty, !tenant.isEmpty, !ownerSession.isEmpty,
              !account.isEmpty, !installation.isEmpty,
              enrolledKeyVersion == nil || enrolledKeyVersion! > 0 else {
            throw SecureRunnerStatusClient.Failure.identityMismatch
        }
        self.client = try SecureRunnerStatusClient(
            trustedAliceOrigin: trustedAliceOrigin,
            testProtocolClasses: testProtocolClasses)
        self.origin = trustedAliceOrigin
        self.humanBearer = humanBearer
        self.jobID = jobID
        self.tenant = tenant
        self.ownerSession = ownerSession
        self.account = account
        self.installation = installation
        self.enrolledKeyVersion = enrolledKeyVersion
    }

    /// The Hermes marker is only a deny-legacy hint. It never supplies identity
    /// or grants access to any other job in the authenticated Alice channel.
    func status(
        errandID: String, markedR02: Bool, hermesOriginSession: String
    ) async throws -> SecureRunnerStatusClient.Observation {
        guard markedR02, errandID == jobID,
              hermesOriginSession == ownerSession else {
            throw SecureRunnerStatusClient.Failure.identityMismatch
        }
        return try await client.status(
            baseURL: origin, humanBearer: humanBearer, jobID: jobID,
            tenant: tenant, session: ownerSession)
    }

    /// Called only by the explicit review sheet with the still-current
    /// authenticated observation. Secure Enclave can ask for biometrics OR
    /// device passcode; neither implies remote account attestation.
    func approveReviewedFictionalCheckout(
        _ observation: SecureRunnerStatusClient.Observation
    ) async throws {
        guard !approvalInFlight, !enrollmentInFlight, !cancellationInFlight,
              observation.isFictionalOnly, observation.status == .pending,
              let version = enrolledKeyVersion,
              let checkout = observation.checkout,
              let checkoutData = observation.checkoutData,
              let challengeData = observation.approvalChallengeData else {
            throw SecureRunnerStatusClient.Failure.notAuthorized
        }
        approvalInFlight = true
        defer { approvalInFlight = false }
        let signature = try SecureRunnerDeviceSigner.signValidatedConsent(
            checkoutData: checkoutData, challengeData: challengeData,
            tenant: tenant, session: ownerSession, jobID: jobID,
            account: account, installation: installation,
            deviceKeyVersion: version, now: Int(Date().timeIntervalSince1970))
        try await client.submitFictionalHumanSignature(
            baseURL: origin, humanBearer: humanBearer, jobID: jobID,
            tenant: tenant, ownerSession: ownerSession,
            checkoutID: checkout.checkoutID, signature: signature)
    }

    /// The only route to a local signing key: explicit human action, a trusted
    /// fixture account session, a fresh server challenge and a scoped P256
    /// possession proof. No local key creation alone marks a device enrolled.
    func enrollFictionalDevice() async throws {
        guard enrolledKeyVersion == nil, !enrollmentInFlight, !approvalInFlight,
              !cancellationInFlight else {
            throw SecureRunnerStatusClient.Failure.notAuthorized
        }
        enrollmentInFlight = true
        defer { enrollmentInFlight = false }
        let generation = 1
        let now = Int(Date().timeIntervalSince1970)
        let publicPEM = try SecureRunnerDeviceSigner.publicKeyForEnrollment(
            tenant: tenant, session: ownerSession, account: account,
            installation: installation, generation: generation)
        let challenge = try await client.beginFictionalDeviceEnrollment(
            baseURL: origin, humanBearer: humanBearer, publicPEM: publicPEM,
            keyExpiresAt: now + 86_400 * 30)
        // Exact scope, public key, replay window and canonical challenge.
        _ = try SecureRunnerEnrollmentContract.checkedProofBytes(
            challengeData: challenge, publicKeyPEM: publicPEM,
            tenant: tenant, session: ownerSession, account: account,
            installation: installation, generation: generation,
            now: Int(Date().timeIntervalSince1970))
        let signature = try SecureRunnerDeviceSigner.signValidatedEnrollmentProof(
            challengeData: challenge, tenant: tenant, session: ownerSession,
            account: account, installation: installation, generation: generation,
            now: Int(Date().timeIntervalSince1970))
        try await client.completeFictionalDeviceEnrollment(
            baseURL: origin, humanBearer: humanBearer,
            challengeData: challenge, signature: signature,
            tenant: tenant, ownerSession: ownerSession,
            account: account, installation: installation,
            expectedVersion: generation)
        enrolledKeyVersion = generation
    }

    /// Explicit human cancellation of a fictional runner job, never a
    /// merchant reversal. UNKNOWN and dispatching outcomes cannot be stopped
    /// or retried by this path; the independent server decides atomically.
    func cancelFictionalJob() async throws -> Bool {
        guard !cancellationInFlight, !approvalInFlight, !enrollmentInFlight else {
            throw SecureRunnerStatusClient.Failure.notAuthorized
        }
        cancellationInFlight = true
        defer { cancellationInFlight = false }
        return try await client.cancelFictionalJob(
            baseURL: origin, humanBearer: humanBearer, jobID: jobID,
            tenant: tenant, ownerSession: ownerSession)
    }
}

private struct SecureRunnerChannelKey: EnvironmentKey {
    static let defaultValue: SecureRunnerAuthenticatedChannel? = nil
}

extension EnvironmentValues {
    var secureRunnerAuthenticatedChannel: SecureRunnerAuthenticatedChannel? {
        get { self[SecureRunnerChannelKey.self] }
        set { self[SecureRunnerChannelKey.self] = newValue }
    }
}

/// Read-only until an independently authenticated Alice channel exists.
/// No legacy checkout, agent answer, or cached status can populate this panel.
struct SecureRunnerConnectedPanel: View {
    @Environment(\.secureRunnerAuthenticatedChannel) private var channel
    let errand: Errand

    @State private var observation: SecureRunnerStatusClient.Observation?
    @State private var reviewSnapshot: SecureRunnerStatusClient.Observation?
    @State private var observationChannelID: UUID?
    @State private var loading = false
    @State private var enrolling = false
    @State private var submitting = false
    @State private var cancelling = false
    @State private var errorMessage: String?
    @State private var showingReview = false
    @State private var showingEnrollment = false
    @State private var showingStopConfirmation = false

    private var bound: Bool {
        guard let channel else { return false }
        return errand.secureRunnerMarker == true && errand.id == channel.jobID
            && errand.originSession == channel.ownerSession
    }

    private var canReview: Bool {
        bound && !loading && !submitting && !enrolling && !cancelling
            && observationChannelID == channel?.id && channel?.enrolledKeyVersion != nil
            && observation?.status == .pending
            && observation?.checkout != nil
            && observation?.checkoutData != nil
            && observation?.approvalChallengeData != nil
    }

    private var canCancel: Bool {
        guard bound, !loading, !submitting, !enrolling, !cancelling,
              observationChannelID == channel?.id, let status = observation?.status else {
            return false
        }
        return [.researching, .cartReady, .pending, .approved].contains(status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureRunnerStatusCard(
                status: bound && observationChannelID == channel?.id
                    ? (observation?.status ?? .unverified) : .unverified,
                language: errand.language)
            if bound {
                Text(errand.language.pick(
                    "Fictional Alice test merchant only · no real payment capability",
                    "Solo comercio ficticio de prueba Alice · sin capacidad de pago real"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    Task { await refresh() }
                } label: {
                    if loading { ProgressView() }
                    else { Label(errand.language.pick("Refresh trusted status", "Actualizar estado verificado"),
                                 systemImage: "arrow.clockwise") }
                }
                .disabled(loading || submitting || cancelling)
                .accessibilityIdentifier("secureRunner.refreshTrustedStatus")

                Button(errand.language.pick("Device enrollment", "Inscripción del dispositivo")) {
                    showingEnrollment = true
                }
                .accessibilityIdentifier("secureRunner.enrollmentInfo")

                if canReview {
                    Button(errand.language.pick("Review fictional checkout", "Revisar pedido ficticio")) {
                        reviewSnapshot = observation
                        showingReview = true
                    }
                    .accessibilityIdentifier("secureRunner.reviewFictionalCheckout")
                }
                if canCancel {
                    Button(role: .destructive) {
                        showingStopConfirmation = true
                    } label: {
                        Label(errand.language.pick("Cancel fictional shopping", "Cancelar compra ficticia"),
                              systemImage: "xmark.shield")
                    }
                    .accessibilityIdentifier("secureRunner.cancelFictionalShopping")
                }
            } else {
                Text(errand.language.pick(
                    "An independent Alice account connection is not available. No approval or payment can be made from this Hermes errand.",
                    "No hay conexión independiente con una cuenta Alice. Este recado de Hermes no permite aprobar ni pagar."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if submitting { ProgressView(errand.language.pick("Sending fictional signature…", "Enviando firma ficticia…")) }
            if cancelling { ProgressView(errand.language.pick("Stopping fictional shopping…", "Deteniendo compra ficticia…")) }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("secureRunner.connectionError")
            }
        }
        .task(id: "\(channel?.id.uuidString ?? "disconnected"):\(errand.id):\(errand.originSession)") {
            observation = nil
            reviewSnapshot = nil
            observationChannelID = nil
            errorMessage = nil
            if bound { await refresh() }
        }
        .confirmationDialog(
            errand.language.pick("Stop this fictional shopping job?", "¿Detener esta compra ficticia?"),
            isPresented: $showingStopConfirmation, titleVisibility: .visible
        ) {
            Button(errand.language.pick("Stop fictional shopping", "Detener compra ficticia"),
                   role: .destructive) {
                Task { await cancelFictionalShopping() }
            }
            Button(errand.language.pick("Keep reviewing", "Seguir revisando"), role: .cancel) {}
        } message: {
            Text(errand.language.pick(
                "Cancellation only invalidates a checkout that has not been sent. If an effect is uncertain, verify the merchant's independent receipt; never resubmit.",
                "La cancelación solo invalida un pedido que no se ha enviado. Si hay un efecto incierto, verifica el recibo independiente del comercio; nunca reenvíes."))
        }
        .sheet(isPresented: $showingEnrollment) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Label(errand.language.pick("Independent account enrollment", "Inscripción independiente"),
                          systemImage: "key.horizontal")
                        .font(.headline)
                    Text(channel?.enrolledKeyVersion == nil
                         ? errand.language.pick(
                            "No enrolled Alice signing key is verified. The independent Alice identity and enrollment service must authenticate this device before an approval is possible.",
                            "No hay ninguna clave de firma Alice inscrita y verificada. El servicio independiente de identidad e inscripción de Alice debe autenticar este dispositivo antes de aprobar nada.")
                         : errand.language.pick(
                            "A device key is recorded for this independent Alice session. Signing requires device authentication (Face ID, Touch ID or passcode). This does not attest your identity to a remote merchant.",
                            "Hay una clave de dispositivo registrada para esta sesión Alice. La firma requiere autenticación del dispositivo (Face ID, Touch ID o código). No acredita por sí sola tu identidad ante un comercio."))
                    if bound && channel?.enrolledKeyVersion == nil {
                        Button(errand.language.pick(
                            "Enroll this device in the fictional test account",
                            "Inscribir este dispositivo en la cuenta ficticia de prueba")) {
                            Task { await enroll() }
                        }
                        .disabled(enrolling || loading || submitting)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("secureRunner.enrollFictionalDevice")
                    }
                    if enrolling {
                        ProgressView(errand.language.pick(
                            "Verifying fictional device enrollment…",
                            "Verificando inscripción ficticia…"))
                    }
                    Spacer()
                }
                .padding()
                .navigationTitle(errand.language.pick("Device enrollment", "Inscripción"))
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(errand.language.pick("Close", "Cerrar")) { showingEnrollment = false }
                } }
            }
        }
        .sheet(isPresented: $showingReview) {
            if let reviewSnapshot, let checkout = reviewSnapshot.checkout {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(errand.language.pick("Fictional checkout · no real payment", "Pedido ficticio · sin pago real"))
                            .font(.headline)
                        LabeledContent(errand.language.pick("Merchant", "Comercio"), value: checkout.merchant)
                        LabeledContent("SKU", value: checkout.sku)
                        LabeledContent(errand.language.pick("Variant", "Variante"), value: checkout.variant)
                        LabeledContent(errand.language.pick("Quantity", "Cantidad"), value: String(checkout.quantity))
                        LabeledContent(errand.language.pick("Recipient", "Destinatario"), value: checkout.recipient)
                        LabeledContent(errand.language.pick("Subtotal", "Subtotal"), value: money(checkout.subtotalMinor))
                        LabeledContent(errand.language.pick("Tax", "Impuestos"), value: money(checkout.taxMinor))
                        LabeledContent(errand.language.pick("Shipping", "Envío"), value: money(checkout.shippingMinor))
                        LabeledContent(errand.language.pick("Discount", "Descuento"), value: money(checkout.discountMinor))
                        LabeledContent(errand.language.pick("Total", "Total"), value: money(checkout.amountMinor))
                            .fontWeight(.semibold)
                        Text(errand.language.pick(
                            "Signing authorizes only this exact fictional challenge. Device authentication may use your passcode. A successful signature is not a confirmed order.",
                            "La firma autoriza únicamente este reto ficticio. La autenticación puede usar tu código. Una firma correcta no confirma el pedido."))
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(errand.language.pick("Sign this fictional approval", "Firmar esta aprobación ficticia")) {
                            showingReview = false
                            Task { await approve(reviewSnapshot) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canReview)
                        .accessibilityIdentifier("secureRunner.signReviewedFictionalCheckout")
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .navigationTitle(errand.language.pick("Review checkout", "Revisar pedido"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button(errand.language.pick("Cancel", "Cancelar")) { showingReview = false }
                    } }
                }
            }
        }
    }

    private func money(_ minor: Int) -> String {
        String(format: "%.2f EUR", Double(minor) / 100)
    }

    @MainActor
    private func enroll() async {
        guard bound, !enrolling, !loading, !submitting,
              let channel, channel.enrolledKeyVersion == nil else { return }
        enrolling = true
        defer { enrolling = false }
        do {
            try await channel.enrollFictionalDevice()
            guard !Task.isCancelled, self.channel?.id == channel.id else { return }
            showingEnrollment = false
            errorMessage = errand.language.pick(
                "Device enrolled in the fictional Alice fixture only. No payment access was enabled.",
                "Dispositivo inscrito solo en la prueba ficticia de Alice. No se han habilitado pagos.")
        } catch {
            guard !Task.isCancelled, self.channel?.id == channel.id else { return }
            errorMessage = errand.language.pick(
                "Device enrollment not verified. No purchase or approval was submitted.",
                "No se ha verificado la inscripción del dispositivo. No se ha enviado ninguna compra ni aprobación.")
            showingEnrollment = false
        }
    }

    @MainActor
    private func refresh() async {
        guard !loading, !submitting, bound, let channel else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await channel.status(
                errandID: errand.id, markedR02: errand.secureRunnerMarker == true,
                hermesOriginSession: errand.originSession)
            guard !Task.isCancelled, self.channel?.id == channel.id else { return }
            observation = result
            observationChannelID = channel.id
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, self.channel?.id == channel.id else { return }
            observation = nil
            observationChannelID = nil
            errorMessage = errand.language.pick(
                "The trusted Alice status could not be verified. No payment was initiated.",
                "No se ha podido verificar el estado de Alice. No se ha iniciado ningún pago.")
        }
    }

    @MainActor
    private func approve(_ reviewed: SecureRunnerStatusClient.Observation) async {
        guard canReview, let channel, let observation,
              reviewed.checkoutData == observation.checkoutData,
              reviewed.approvalChallengeData == observation.approvalChallengeData,
              reviewed.checkout?.checkoutID == observation.checkout?.checkoutID else {
            errorMessage = errand.language.pick(
                "The checkout changed. Refresh and review it again.",
                "El pedido ha cambiado. Actualiza y revísalo de nuevo.")
            return
        }
        submitting = true
        defer { submitting = false }
        do {
            try await channel.approveReviewedFictionalCheckout(reviewed)
            guard !Task.isCancelled, self.channel?.id == channel.id else { return }
            // An approval acknowledgement is not proof of purchase.
            self.observation = nil
            observationChannelID = nil
            errorMessage = errand.language.pick(
                "Fictional signature accepted. Refresh trusted status to verify the outcome.",
                "Firma ficticia aceptada. Actualiza el estado verificado para comprobar el resultado.")
        } catch {
            guard !Task.isCancelled, self.channel?.id == channel.id else { return }
            self.observation = nil
            observationChannelID = nil
            errorMessage = errand.language.pick(
                "Approval could not be verified. Do not retry without a fresh independent status.",
                "No se ha podido verificar la aprobación. No reintentes sin consultar primero el estado independiente.")
        }
    }

    @MainActor
    private func cancelFictionalShopping() async {
        guard canCancel, let channel else { return }
        cancelling = true
        defer { cancelling = false }
        do {
            let browserClosed = try await channel.cancelFictionalJob()
            guard !Task.isCancelled, self.channel?.id == channel.id else { return }
            observation = nil
            reviewSnapshot = nil
            observationChannelID = nil
            errorMessage = browserClosed
                ? errand.language.pick(
                    "Fictional shopping stopped. Refresh the trusted status to confirm.",
                    "Compra ficticia detenida. Actualiza el estado verificado para confirmarlo.")
                : errand.language.pick(
                    "Fictional stop was recorded, but browser closure was not verified. Do not retry.",
                    "Se registró la detención ficticia, pero no se verificó el cierre del navegador. No reintentes.")
        } catch {
            guard !Task.isCancelled, self.channel?.id == channel.id else { return }
            observation = nil
            reviewSnapshot = nil
            observationChannelID = nil
            errorMessage = errand.language.pick(
                "Cancellation was not independently verified. A merchant effect may be uncertain; refresh status before any action.",
                "La cancelación no se ha verificado de forma independiente. Puede haber un efecto comercial incierto; actualiza el estado antes de actuar.")
        }
    }
}
