#if os(tvOS)
import Foundation
import Observation
import StoreKit
import SwiftUI
import SmartTubeIOSCore

/// The App Store products sold by the standalone iTube tvOS app.
/// Prices are always rendered from StoreKit metadata; these identifiers must
/// match the products configured in App Store Connect.
public enum ITubeProductID {
    public static let monthly = "com.denis.PersonalTubeTV.plus.monthly"
    public static let annual = "com.denis.PersonalTubeTV.plus.annual"
    public static let lifetime = "com.denis.PersonalTubeTV.plus.lifetime"

    public static let paid = [monthly, annual, lifetime]
    public static let all = paid

    static func sortOrder(for id: String) -> Int {
        switch id {
        case monthly: 0
        case annual: 1
        case lifetime: 2
        default: 3
        }
    }
}

public struct ITubeEntitlement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case monthly
        case annual
        case lifetime
    }

    public let kind: Kind
    public let productID: String
    public let expirationDate: Date?
    public let isFamilyShared: Bool

    init(transaction: StoreKit.Transaction) {
        productID = transaction.productID
        expirationDate = transaction.expirationDate
        isFamilyShared = transaction.ownershipType == .familyShared
        switch transaction.productID {
        case ITubeProductID.annual:
            kind = .annual
        case ITubeProductID.lifetime:
            kind = .lifetime
        default:
            kind = .monthly
        }
    }

    init(kind: Kind, productID: String, expirationDate: Date?, isFamilyShared: Bool) {
        self.kind = kind
        self.productID = productID
        self.expirationDate = expirationDate
        self.isFamilyShared = isFamilyShared
    }
}

@MainActor
@Observable
public final class AppAccessStore {
    private enum DefaultsKey {
        static let freeWeekStartDate = "faketube.plus.freeWeekStartDate"
        static let lastOfferPresentationDate = "faketube.plus.lastOfferPresentationDate"
    }

    public enum AccessState: Equatable, Sendable {
        case loading
        case entitled(ITubeEntitlement)
        case locked
    }

    public private(set) var accessState: AccessState = .loading
    public private(set) var products: [Product] = []
    public private(set) var purchasingProductID: String?
    public private(set) var isRestoring = false
    public private(set) var isLoadingProducts = false
    public private(set) var evaluationDate: Date
    public private(set) var freeWeekStartDate: Date
    public var message: String?

    public var paidProducts: [Product] {
        products.filter { ITubeProductID.paid.contains($0.id) }
    }

    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var hasPrepared = false
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let now = Date()
        evaluationDate = now

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-expired-free-week") {
            freeWeekStartDate = now.addingTimeInterval(-FreeWeekSchedule.duration - 1)
            return
        }
        #endif

        if let storedStart = defaults.object(forKey: DefaultsKey.freeWeekStartDate) as? Date {
            freeWeekStartDate = storedStart
        } else {
            freeWeekStartDate = now
            defaults.set(now, forKey: DefaultsKey.freeWeekStartDate)
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    public var hasPlusAccess: Bool {
        switch accessState {
        case .entitled:
            true
        case .loading, .locked:
            false
        }
    }

    public var isFreeWeekActive: Bool {
        freeWeekSchedule.isActive(at: evaluationDate)
    }

    public var freeWeekDaysRemaining: Int {
        freeWeekSchedule.daysRemaining(at: evaluationDate)
    }

    public var shouldPresentPostWeekOffer: Bool {
        let lastPresentation = defaults.object(
            forKey: DefaultsKey.lastOfferPresentationDate
        ) as? Date
        return freeWeekSchedule.shouldPresentOffer(
            at: evaluationDate,
            lastPresentedAt: lastPresentation,
            hasPaidAccess: hasPlusAccess
        )
    }

    public var statusText: String {
        switch accessState {
        case .loading:
            return String(localized: "Checking access…", bundle: .module)
        case .entitled(let entitlement):
            let shared = entitlement.isFamilyShared
                ? String(localized: " · Family Shared", bundle: .module)
                : ""
            switch entitlement.kind {
            case .monthly:
                return String(localized: "iTube Plus · Monthly", bundle: .module) + shared
            case .annual:
                return String(localized: "iTube Plus · Annual", bundle: .module) + shared
            case .lifetime:
                return String(localized: "iTube Plus · Lifetime", bundle: .module) + shared
            }
        case .locked:
            if isFreeWeekActive {
                return String(
                    localized: "Free week · \(freeWeekDaysRemaining) days remaining",
                    bundle: .module
                )
            }
            return String(localized: "Free access", bundle: .module)
        }
    }

    public func recordPostWeekOfferPresentation() {
        defaults.set(evaluationDate, forKey: DefaultsKey.lastOfferPresentationDate)
    }

    public func prepare() async {
        if !hasPrepared {
            hasPrepared = true
            startObservingTransactions()
        }
        await refreshAccess()
        await loadProducts()
    }

    public func refreshAccess() async {
        evaluationDate = Date()

        if hasDebugArgument("--uitesting-unlocked") {
            message = nil
            accessState = .entitled(
                ITubeEntitlement(
                    kind: .lifetime,
                    productID: ITubeProductID.lifetime,
                    expirationDate: nil,
                    isFamilyShared: false
                )
            )
            return
        }

        if let entitlement = await currentEntitlement() {
            message = nil
            accessState = .entitled(entitlement)
            return
        }

        message = nil
        accessState = .locked
    }

    public func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let loaded = try await Product.products(for: ITubeProductID.all)
            products = loaded.sorted {
                ITubeProductID.sortOrder(for: $0.id) < ITubeProductID.sortOrder(for: $1.id)
            }
            if loaded.count == ITubeProductID.all.count {
                if message == String(localized: "Plans are temporarily unavailable. Try again.", bundle: .module)
                    || message == String(localized: "Some purchase options are temporarily unavailable.", bundle: .module) {
                    message = nil
                }
            } else {
                message = String(localized: "Some purchase options are temporarily unavailable.", bundle: .module)
            }
        } catch {
            products = []
            message = String(localized: "Plans are temporarily unavailable. Try again.", bundle: .module)
        }
    }

    public func purchase(_ product: Product) async {
        guard purchasingProductID == nil, !isRestoring else { return }
        purchasingProductID = product.id
        message = nil
        defer { purchasingProductID = nil }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = String(localized: "Apple could not verify this purchase.", bundle: .module)
                    return
                }
                await transaction.finish()
                await refreshAccess()
            case .pending:
                message = String(localized: "Purchase pending approval. Access will unlock automatically when Apple approves it.", bundle: .module)
            case .userCancelled:
                break
            @unknown default:
                message = String(localized: "The purchase could not be completed.", bundle: .module)
            }
        } catch {
            message = String(localized: "The purchase could not be completed. Check your Apple Account and try again.", bundle: .module)
        }
    }

    public func restorePurchases() async {
        guard !isRestoring, purchasingProductID == nil else { return }
        isRestoring = true
        message = nil
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshAccess()
            switch accessState {
            case .locked:
                message = String(localized: "No active purchase was found for this Apple Account.", bundle: .module)
            case .loading, .entitled:
                break
            }
        } catch {
            message = String(localized: "Purchases could not be restored. Check your connection and try again.", bundle: .module)
        }
    }

    public func retryStore() async {
        message = nil
        await refreshAccess()
        await loadProducts()
    }

    public func monthlyEquivalent(for product: Product) -> String? {
        guard product.id == ITubeProductID.annual else { return nil }
        return (product.price / Decimal(12)).formatted(product.priceFormatStyle)
    }

    private func startObservingTransactions() {
        transactionUpdatesTask = Task { [weak self] in
            for await verification in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = verification else { continue }
                await transaction.finish()
                await self.refreshAccess()
            }
        }
    }

    private func currentEntitlement() async -> ITubeEntitlement? {
        var active: [ITubeEntitlement] = []
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification,
                  ITubeProductID.paid.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else { continue }
            active.append(ITubeEntitlement(transaction: transaction))
        }

        // A non-consumable lifetime purchase is authoritative if more than one
        // entitlement is present during a StoreKit transition.
        return active.first(where: { $0.kind == .lifetime })
            ?? active.max { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) }
    }

    private func hasDebugArgument(_ argument: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }

    private var freeWeekSchedule: FreeWeekSchedule {
        FreeWeekSchedule(startDate: freeWeekStartDate)
    }
}

public struct TVAccessGate<Content: View>: View {
    @Environment(AppAccessStore.self) private var accessStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPostWeekOffer = false
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
        .task {
            await accessStore.prepare()
            presentPostWeekOfferIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await accessStore.prepare()
                presentPostWeekOfferIfNeeded()
            }
        }
        .fullScreenCover(isPresented: $showPostWeekOffer) {
            TVPaywallView(allowsDismissal: true, isPostWeekPrompt: true)
                .environment(accessStore)
        }
    }

    private func presentPostWeekOfferIfNeeded() {
        guard accessStore.shouldPresentPostWeekOffer else { return }
        accessStore.recordPostWeekOfferPresentation()
        showPostWeekOffer = true
    }
}

public struct TVPaywallView: View {
    private enum FocusTarget: Hashable {
        case plan(String)
        case continueFree
        case restore
        case legal
    }

    @Environment(AppAccessStore.self) private var accessStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLegal = false
    @FocusState private var focusedControl: FocusTarget?
    @Namespace private var focusNamespace

    private let allowsDismissal: Bool
    private let isPostWeekPrompt: Bool

    public init(allowsDismissal: Bool, isPostWeekPrompt: Bool = false) {
        self.allowsDismissal = allowsDismissal
        self.isPostWeekPrompt = isPostWeekPrompt
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.09, blue: 0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                header

                if case .entitled(let entitlement) = accessStore.accessState {
                    activePurchase(entitlement)
                } else if accessStore.paidProducts.isEmpty {
                    unavailablePlans
                } else {
                    HStack(spacing: 30) {
                        ForEach(accessStore.paidProducts, id: \.id) { product in
                            planButton(product)
                        }
                    }
                    .focusSection()
                }

                if let message = accessStore.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 980)
                        .accessibilityIdentifier("paywall.message")
                }

                HStack(spacing: 24) {
                    if allowsDismissal {
                        Button {
                            dismiss()
                        } label: {
                            Label("Continue Free", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .focused($focusedControl, equals: .continueFree)
                        .accessibilityIdentifier("paywall.continueFreeButton")
                    }

                    Button {
                        Task { await accessStore.restorePurchases() }
                    } label: {
                        Label(
                            accessStore.isRestoring ? "Restoring…" : "Restore Purchases",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .focused($focusedControl, equals: .restore)
                    .disabled(accessStore.isRestoring || accessStore.purchasingProductID != nil)
                    .accessibilityIdentifier("paywall.restoreButton")

                    Button {
                        showLegal = true
                    } label: {
                        Label("Privacy, Terms & Support", systemImage: "doc.text")
                    }
                    .focused($focusedControl, equals: .legal)
                    .accessibilityIdentifier("paywall.legalButton")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(subscriptionDisclosure)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1050)
            }
            .padding(.horizontal, 76)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if allowsDismissal {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .padding(38)
            }
        }
        .focusScope(focusNamespace)
        .onChange(of: accessStore.paidProducts.map(\.id), initial: true) { _, productIDs in
            guard !productIDs.isEmpty else { return }
            let preferredID = productIDs.contains(ITubeProductID.monthly)
                ? ITubeProductID.monthly
                : productIDs[0]
            if focusedControl == nil || focusedControl == .restore {
                focusedControl = isPostWeekPrompt ? .continueFree : .plan(preferredID)
            }
        }
        .sheet(isPresented: $showLegal) {
            TVLegalAndSupportView()
        }
        .onExitCommand {
            if allowsDismissal { dismiss() }
        }
        .accessibilityIdentifier("paywall.view")
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)

            Text(headerTitle)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(headerSubtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 960)
        }
    }

    private var headerTitle: String {
        switch accessStore.accessState {
        case .entitled:
            return String(localized: "Your iTube Plus access is active", bundle: .module)
        case .loading, .locked:
            return accessStore.isFreeWeekActive
                ? String(localized: "Your free week is active", bundle: .module)
                : String(localized: "Choose iTube Plus", bundle: .module)
        }
    }

    private var headerSubtitle: String {
        switch accessStore.accessState {
        case .entitled(let entitlement):
            if entitlement.kind == .lifetime {
                return String(localized: "Lifetime access is unlocked. There is no recurring iTube charge.", bundle: .module)
            }
            return String(localized: "Manage, change, or cancel your subscription in Apple TV Settings.", bundle: .module)
        case .loading, .locked:
            if accessStore.isFreeWeekActive {
                return String(
                    localized: "\(accessStore.freeWeekDaysRemaining) days remaining. Choose Plus now or keep watching free.",
                    bundle: .module
                )
            }
            return String(localized: "Subscribe for Plus, or continue watching free.", bundle: .module)
        }
    }

    private func activePurchase(_ entitlement: ITubeEntitlement) -> some View {
        VStack(spacing: 18) {
            Image(systemName: entitlement.kind == .lifetime ? "checkmark.seal.fill" : "checkmark.circle.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(activePlanName(entitlement.kind))
                .font(.title2.weight(.semibold))

            if let expirationDate = entitlement.expirationDate, expirationDate > Date() {
                Text("Current subscription access through \(expirationDate.formatted(date: .long, time: .omitted))")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else if entitlement.kind != .lifetime {
                Text("Subscription access is active while Apple resolves the renewal.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                Text("One-time purchase · no renewal")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("To avoid overlapping purchases, plans are not sold again while access is active.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: 860, minHeight: 250)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.activePurchase")
    }

    private func activePlanName(_ kind: ITubeEntitlement.Kind) -> String {
        switch kind {
        case .monthly:
            String(localized: "Monthly plan active", bundle: .module)
        case .annual:
            String(localized: "Annual plan active", bundle: .module)
        case .lifetime:
            String(localized: "Lifetime access active", bundle: .module)
        }
    }

    private var unavailablePlans: some View {
        VStack(spacing: 20) {
            if accessStore.isLoadingProducts {
                ProgressView(String(localized: "Loading plans…", bundle: .module))
            } else {
                ContentUnavailableView(
                    "Plans Unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text("Check your connection, then try again. You can still restore an existing purchase.")
                )
                Button("Try Again") {
                    Task { await accessStore.retryStore() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: 1160, minHeight: 290)
    }

    private func planButton(_ product: Product) -> some View {
        Button {
            Task { await accessStore.purchase(product) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: planSymbol(for: product.id))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(planName(for: product.id))
                    .font(.title3.weight(.semibold))

                Text(product.displayPrice)
                    .font(.title2.weight(.bold))

                Text(planDetail(for: product))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                if accessStore.purchasingProductID == product.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(planAction(for: product), systemImage: "arrow.right.circle.fill")
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(22)
            .frame(width: 350, height: 330, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.card)
        .focused($focusedControl, equals: .plan(product.id))
        .disabled(accessStore.purchasingProductID != nil || accessStore.isRestoring)
        .prefersDefaultFocus(
            !isPostWeekPrompt && product.id == ITubeProductID.monthly,
            in: focusNamespace
        )
        .accessibilityIdentifier("paywall.plan.\(product.id)")
        .accessibilityLabel("\(planName(for: product.id)), \(product.displayPrice), \(planDetail(for: product))")
    }

    private func planName(for productID: String) -> String {
        switch productID {
        case ITubeProductID.monthly:
            return String(localized: "Monthly", bundle: .module)
        case ITubeProductID.annual:
            return String(localized: "Annual", bundle: .module)
        case ITubeProductID.lifetime:
            return String(localized: "Lifetime", bundle: .module)
        default:
            return String(localized: "iTube Plus", bundle: .module)
        }
    }

    private func planDetail(for product: Product) -> String {
        switch product.id {
        case ITubeProductID.monthly:
            return String(localized: "Billed monthly", bundle: .module)
        case ITubeProductID.annual:
            if let monthly = accessStore.monthlyEquivalent(for: product) {
                return String(localized: "\(monthly)/month · billed yearly", bundle: .module)
            }
            return String(localized: "Billed yearly", bundle: .module)
        case ITubeProductID.lifetime:
            return String(localized: "One payment · lifetime", bundle: .module)
        default:
            return ""
        }
    }

    private func planAction(for product: Product) -> String {
        if product.id == ITubeProductID.lifetime {
            return String(localized: "Buy Once", bundle: .module)
        }
        return String(localized: "Subscribe", bundle: .module)
    }

    private var subscriptionDisclosure: String {
        String(localized: "Subscriptions start immediately and renew automatically until cancelled. Apple charges the displayed price when you confirm. Manage or cancel in Apple TV Settings. Lifetime is a one-time purchase. Free viewing remains available without a purchase.", bundle: .module)
    }

    private func planSymbol(for productID: String) -> String {
        switch productID {
        case ITubeProductID.monthly: "calendar"
        case ITubeProductID.annual: "calendar.badge.checkmark"
        case ITubeProductID.lifetime: "infinity"
        default: "play.tv"
        }
    }
}

struct TVLegalAndSupportView: View {
    private enum Destination: String, CaseIterable, Identifiable {
        case privacy
        case terms
        case support
        case subscriptions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .privacy: "Privacy Policy"
            case .terms: "Terms of Use"
            case .support: "Support"
            case .subscriptions: "Manage Subscriptions"
            }
        }

        var symbol: String {
            switch self {
            case .privacy: "hand.raised.fill"
            case .terms: "doc.text.fill"
            case .support: "questionmark.circle.fill"
            case .subscriptions: "person.crop.circle.badge.checkmark"
            }
        }

        var url: String {
            switch self {
            case .privacy:
                "https://funnymataleao.github.io/iTube/privacy/"
            case .terms:
                "https://funnymataleao.github.io/iTube/terms/"
            case .support:
                "https://funnymataleao.github.io/iTube/support/"
            case .subscriptions:
                "https://apps.apple.com/account/subscriptions"
            }
        }

        var detail: String {
            switch self {
            case .privacy:
                "How iTube handles account, playback, diagnostics, and purchase data."
            case .terms:
                "iTube's terms, purchase conditions, and the linked Apple Standard EULA."
            case .support:
                "Report a problem or contact the developer through the public support page."
            case .subscriptions:
                "On Apple TV, open Settings → Profiles and Accounts → your profile → Subscriptions."
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Destination = .privacy

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.94).ignoresSafeArea()

            HStack(spacing: 72) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Legal & Support")
                        .font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)

                    ForEach(Destination.allCases) { destination in
                        if destination == selection {
                            destinationButton(destination)
                                .buttonStyle(.borderedProminent)
                        } else {
                            destinationButton(destination)
                                .buttonStyle(.bordered)
                        }
                    }
                }

                VStack(spacing: 22) {
                    Text(selection.title)
                        .font(.title.weight(.semibold))

                    Text(selection.detail)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)

                    QRCodeView(content: selection.url)
                        .frame(width: 300, height: 300)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Text(selection.url)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 700)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(70)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .padding(38)
        }
        .onExitCommand { dismiss() }
    }

    private func destinationButton(_ destination: Destination) -> some View {
        Button {
            selection = destination
        } label: {
            Label(destination.title, systemImage: destination.symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 430, alignment: .leading)
                .padding(.vertical, 8)
        }
    }
}
#endif
