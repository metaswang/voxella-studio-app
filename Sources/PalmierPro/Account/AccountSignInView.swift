import SwiftUI

struct AccountSignInView: View {
    @Bindable private var account = AccountService.shared
    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @FocusState private var focusedField: SignInField?

    private enum SignInField: Hashable {
        case email
        case password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Sign in to VoxStudio")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Sign in to subscribe and use AI generation.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AppTheme.Spacing.smMd) {
                providerButton(
                    title: account.isSigningIn ? "Signing in…" : "Continue with Apple",
                    kind: .apple
                ) {
                    Task { await account.signInWithApple() }
                }
                providerButton(
                    title: account.isSigningIn ? "Signing in…" : "Continue with Google",
                    kind: .google
                ) {
                    Task { await account.signInWithGoogle() }
                }
            }
            .disabled(account.isSigningIn)

            authDivider
            emailSignInForm
        }
        .frame(maxWidth: AppTheme.Auth.contentWidth, alignment: .leading)
        .onChange(of: account.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                password = ""
                focusedField = nil
            }
        }
    }

    private var authDivider: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)
            Text("OR")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private var emailSignInForm: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Email")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField("your@email.com", text: $email)
                    .textFieldStyle(.plain)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                    .authFieldChrome(isFocused: focusedField == .email)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Password")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                HStack(spacing: AppTheme.Spacing.xs) {
                    Group {
                        if isPasswordVisible {
                            TextField("••••••••", text: $password)
                        } else {
                            SecureField("••••••••", text: $password)
                        }
                    }
                    .textFieldStyle(.plain)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .onSubmit(submitEmailLogin)

                    Button {
                        isPasswordVisible.toggle()
                        focusedField = .password
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .font(.system(size: AppTheme.FontSize.mdLg))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: AppTheme.Radius.xs)
                    .help(isPasswordVisible ? "Hide password" : "Show password")
                }
                .authFieldChrome(isFocused: focusedField == .password)
            }

            Button(action: submitEmailLogin) {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    if account.isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppTheme.Auth.primaryForeground)
                    }
                    Text(account.isSigningIn ? "Signing in…" : "Sign in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AuthPrimaryButtonStyle())
            .disabled(!canSubmitEmail)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var canSubmitEmail: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !account.isSigningIn
    }

    private func submitEmailLogin() {
        guard canSubmitEmail else {
            if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                focusedField = .email
            } else if password.isEmpty {
                focusedField = .password
            }
            return
        }

        focusedField = nil
        let submittedEmail = email
        let submittedPassword = password
        Task {
            await account.signInWithEmail(email: submittedEmail, password: submittedPassword)
            if account.isSignedIn {
                password = ""
            }
        }
    }

    private func providerButton(
        title: String,
        kind: AuthProviderButtonStyle.Kind,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                switch kind {
                case .apple:
                    Image(systemName: "apple.logo")
                        .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.medium))
                        .frame(width: AppTheme.IconSize.md)
                        .accessibilityHidden(true)
                case .google:
                    Text("G")
                        .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.bold))
                        .foregroundStyle(AppTheme.Auth.googleMarkGradient)
                        .frame(width: AppTheme.IconSize.md)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuthProviderButtonStyle(kind: kind))
        .pointerStyle(.link)
    }
}

private struct AuthProviderButtonStyle: ButtonStyle {
    enum Kind {
        case apple
        case google
    }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, AppTheme.Spacing.lgXl)
            .frame(height: AppTheme.Auth.providerButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(border, lineWidth: AppTheme.BorderWidth.thin)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(hoverFill)
            )
            .shadow(AppTheme.Shadow.sm)
            .scaleEffect(configuration.isPressed ? AppTheme.Auth.pressedScale : AppTheme.Opacity.opaque)
            .opacity(isEnabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
            .onHover { isHovered = isEnabled && $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
    }

    private var foreground: Color {
        switch kind {
        case .apple: return AppTheme.Auth.appleForeground
        case .google: return AppTheme.Auth.googleForeground
        }
    }

    private var background: Color {
        switch kind {
        case .apple: return AppTheme.Auth.appleBackground
        case .google: return AppTheme.Auth.googleBackground
        }
    }

    private var border: Color {
        switch kind {
        case .apple: return AppTheme.Border.primaryColor
        case .google: return AppTheme.Border.subtleColor
        }
    }

    private var hoverFill: Color {
        guard isEnabled, isHovered else { return .clear }
        return kind == .apple
            ? AppTheme.Auth.appleHoverFill
            : AppTheme.Auth.googleHoverFill
    }
}

private struct AuthPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Auth.primaryForeground)
            .padding(.horizontal, AppTheme.Spacing.lgXl)
            .frame(height: AppTheme.Auth.providerButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(AppTheme.Auth.primaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(isHovered && isEnabled ? AppTheme.Auth.primaryHoverFill : .clear)
            )
            .shadow(AppTheme.Shadow.sm)
            .scaleEffect(configuration.isPressed ? AppTheme.Auth.pressedScale : AppTheme.Opacity.opaque)
            .opacity(isEnabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
            .onHover { isHovered = isEnabled && $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
    }
}

private struct AuthFieldChrome: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppTheme.Spacing.md)
            .frame(height: AppTheme.Auth.fieldHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(AppTheme.Auth.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(
                        isFocused ? AppTheme.Auth.focusBorder : AppTheme.Auth.fieldBorder,
                        lineWidth: isFocused ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin
                    )
            )
    }
}

private extension View {
    func authFieldChrome(isFocused: Bool) -> some View {
        modifier(AuthFieldChrome(isFocused: isFocused))
    }
}
