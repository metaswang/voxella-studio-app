import SwiftUI

// MARK: - UserAvatar

struct UserAvatar: View {
    enum SignedOutStyle {
        case filledCircle
        case bareSymbol
    }

    var diameter: CGFloat
    var fontSize: CGFloat
    var signedOutStyle: SignedOutStyle = .filledCircle

    @Bindable private var account = AccountService.shared

    var body: some View {
        ZStack {
            background
            foreground
            profileImage
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    @ViewBuilder
    private var background: some View {
        if account.isSignedIn {
            Circle().fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium))
        } else if signedOutStyle == .filledCircle {
            Circle().fill(Color.white.opacity(AppTheme.Opacity.soft))
        }
    }

    @ViewBuilder
    private var foreground: some View {
        if account.isSignedIn {
            if account.displayInitial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: fontSize))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            } else {
                Text(account.displayInitial)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
        } else {
            switch signedOutStyle {
            case .filledCircle:
                Image(systemName: "person.fill")
                    .font(.system(size: fontSize))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            case .bareSymbol:
                Image(systemName: "person.crop.circle")
                    .font(.system(size: diameter))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
    }

    @ViewBuilder
    private var profileImage: some View {
        if account.isSignedIn, let urlString = account.account?.user.image,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                        .frame(width: diameter, height: diameter)
                }
            }
            .id(urlString)
        }
    }
}

// MARK: - Workbench identity and operating mode

struct LocalModeIcon: View {
    var diameter: CGFloat

    var body: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: diameter * 0.55, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .frame(width: diameter, height: diameter)
            .background(AppTheme.Background.raisedColor, in: Circle())
            .accessibilityHidden(true)
    }
}

struct WorkbenchIdentityButton: View {
    let isExpanded: Bool
    @Bindable private var account = AccountService.shared
    @State private var isPopoverPresented = false

    private enum Mode: Equatable {
        case loading, local, hybrid, offline
    }

    private var mode: Mode {
        if account.isOfflineAccount { return .offline }
        if account.isSignedIn { return .hybrid }
        if account.isLoading, account.account == nil, !account.isSigningIn { return .loading }
        return .local
    }

    private var shortLabel: String {
        switch mode {
        case .loading: L10n.string("Loading")
        case .local: L10n.string("Local")
        case .hybrid: L10n.string("Hybrid")
        case .offline: L10n.string("Offline")
        }
    }

    private var title: String {
        switch mode {
        case .loading: L10n.string("Loading…")
        case .local: L10n.string("Local mode")
        case .hybrid, .offline: account.displayPrimaryText
        }
    }

    private var subtitle: String {
        switch mode {
        case .loading: L10n.string("Restoring account…")
        case .local: L10n.string("Not signed in")
        case .hybrid: L10n.string("Local + Cloud")
        case .offline: L10n.string("Local mode · Offline")
        }
    }

    var body: some View {
        Button { isPopoverPresented.toggle() } label: {
            Group {
                if isExpanded {
                    HStack(spacing: AppTheme.Spacing.md) {
                        icon
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text(title)
                                .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .truncationMode(.middle)
                            Text(subtitle)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: AppTheme.Spacing.xxs) {
                        icon
                        Text(shortLabel)
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, isExpanded ? AppTheme.Spacing.md : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: AppTheme.zoomed(44))
            .hoverHighlight(isActive: isPopoverPresented)
        }
        .buttonStyle(.plain)
        .disabled(mode == .loading)
        .help([title, subtitle].joined(separator: " · "))
        .accessibilityLabel([title, subtitle].joined(separator: ", "))
        .accessibilityHint(L10n.string(account.isSignedIn ? "View account and mode" : "View local mode details"))
        .accessibilityIdentifier("workbench.identity")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
            if account.isSignedIn {
                AccountPopoverCard()
            } else {
                LocalModePopoverCard()
            }
        }
        .onChange(of: mode) { _, _ in isPopoverPresented = false }
        .onChange(of: account.userID) { _, _ in isPopoverPresented = false }
    }

    @ViewBuilder
    private var icon: some View {
        let diameter = isExpanded ? AppTheme.IconSize.xl : AppTheme.IconSize.mdLg
        switch mode {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(width: diameter, height: diameter)
        case .local:
            LocalModeIcon(diameter: diameter)
        case .hybrid, .offline:
            UserAvatar(diameter: diameter, fontSize: AppTheme.FontSize.smMd)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - UserAvatarButton

struct UserAvatarButton: View {
    @Bindable private var account = AccountService.shared
    @State private var isPopoverPresented = false

    var body: some View {
        Button(action: { isPopoverPresented.toggle() }) {
            UserAvatar(
                diameter: AppTheme.IconSize.sm,
                fontSize: AppTheme.FontSize.xxs,
                signedOutStyle: .bareSymbol
            )
            .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(L10n.string(account.isSignedIn ? "Account" : "Sign in"))
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            AccountPopoverCard()
        }
    }
}

// MARK: - IdentityStrip

struct IdentityStrip: View {
    @Bindable private var account = AccountService.shared
    @State private var isPopoverPresented = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Button(action: { isPopoverPresented.toggle() }) {
                UserAvatar(
                    diameter: AppTheme.IconSize.xl,
                    fontSize: AppTheme.FontSize.mdLg
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
                AccountPopoverCard()
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.display(account.displayPrimaryText))
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondary = account.displaySecondaryText {
                    Text(secondary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.lg)
    }
}
