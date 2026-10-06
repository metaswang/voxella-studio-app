#if !MAC_APP_STORE
import SwiftUI

struct CloudPlanUpgradeRow: View {
    let plan: AvailablePlan
    let comparisonPlans: [AvailablePlan]
    let onUpgrade: () -> Void

    @State private var showsRateDetails = false

    private var isPro: Bool { plan.tier.rawValue == "pro" }
    private var baseline: AvailablePlan? {
        comparisonPlans.first { $0.tier.rawValue == "starter" || $0.tier.rawValue == "basic" }
    }
    private var multiplier: Double? {
        guard let allowance = plan.transcriptionAllowance,
              let base = baseline?.transcriptionAllowance else { return nil }
        return allowance.multiplier(comparedTo: base)
    }
    private var isBestValue: Bool {
        guard isPro, let allowance = plan.transcriptionAllowance,
              let baseline, let base = baseline.transcriptionAllowance,
              baseline.effectiveMonthlyPriceUsd > 0 else { return false }
        return Double(plan.effectiveMonthlyPriceUsd) / allowance.monthlyHours
            < Double(baseline.effectiveMonthlyPriceUsd) / base.monthlyHours
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Text(plan.tier.localizedUpgradeLabel)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if isBestValue {
                    Text(L10n.string("Best value"))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Onboarding.ink)
                        .padding(.horizontal, AppTheme.Spacing.smMd)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .background(AppTheme.Onboarding.ink.opacity(AppTheme.Opacity.soft), in: Capsule())
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                Button(L10n.format("Choose %@", plan.tier.localizedUpgradeLabel), action: onUpgrade)
                    .buttonStyle(.capsule(isPro ? .prominent : .secondary))
                    .controlSize(.small)
                    .accessibilityIdentifier("cloud-plan-upgrade-\(plan.id)")
            }

            HStack(spacing: AppTheme.Spacing.smMd) {
                Text(L10n.format("$%@/mo", plan.effectiveMonthlyPriceUsd))
                if let credits = plan.monthlyBudgetCredits {
                    Text("·").accessibilityHidden(true)
                    Text(L10n.format("%@ credits / month", credits.formatted(.number.locale(AppLocalization.shared.activeLocale))))
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .monospacedDigit()

            if let allowance = plan.transcriptionAllowance {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.smMd) {
                        hoursLabel(allowance)
                            .fixedSize(horizontal: true, vertical: false)
                        comparisonBadge
                        rateInfoButton
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        hoursLabel(allowance)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: AppTheme.Spacing.smMd) {
                            comparisonBadge
                            rateInfoButton
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(LinearGradient(
                    colors: [
                        isPro ? AppTheme.Onboarding.ink.opacity(AppTheme.Opacity.faint) : AppTheme.Background.raisedColor,
                        AppTheme.Background.raisedColor,
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(
                    isPro ? AppTheme.Onboarding.ink.opacity(AppTheme.Opacity.medium) : AppTheme.Border.subtleColor,
                    lineWidth: isPro ? AppTheme.BorderWidth.thin : AppTheme.BorderWidth.hairline
                )
        }
    }

    private func hoursLabel(_ allowance: PlanTranscriptionAllowance) -> some View {
        Text(L10n.format("≈%@ standard transcription hours / month", number(allowance.monthlyHours)))
            .font(.system(size: AppTheme.FontSize.lg, weight: isPro ? .semibold : .medium))
            .foregroundStyle(isPro ? AppTheme.Onboarding.ink : AppTheme.Text.primaryColor)
            .monospacedDigit()
    }

    @ViewBuilder
    private var comparisonBadge: some View {
        if let multiplier {
            Text(L10n.format("%@× transcription", number(multiplier)))
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(isPro ? AppTheme.Onboarding.ink : AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(
                    isPro ? AppTheme.Onboarding.ink.opacity(AppTheme.Opacity.soft) : AppTheme.Interaction.fill(AppTheme.Opacity.faint),
                    in: Capsule()
                )
                .fixedSize()
        }
    }

    private var rateInfoButton: some View {
        Button { showsRateDetails = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: AppTheme.FontSize.mdLg))
                .foregroundStyle(isPro ? AppTheme.Onboarding.ink : AppTheme.Text.secondaryColor)
                .padding(AppTheme.Spacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.string("Compare transcription rates"))
        .accessibilityLabel(L10n.string("Compare transcription rates"))
        .accessibilityIdentifier("cloud-plan-rates-info-\(plan.id)")
        .popover(isPresented: $showsRateDetails, arrowEdge: .bottom) {
            rateDetails
        }
    }

    private var rateDetails: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            Text(L10n.string("Why Pro goes further"))
                .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            ForEach(comparisonPlans.filter { $0.tier.rawValue == "starter" || $0.tier.rawValue == "basic" || $0.tier.rawValue == "pro" }) { comparison in
                if let allowance = comparison.transcriptionAllowance {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                        Text(comparison.tier.localizedUpgradeLabel)
                            .fontWeight(.semibold)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        VStack(alignment: .trailing, spacing: AppTheme.Spacing.xs) {
                            Text(L10n.format("%@ credits / hour", number(allowance.creditsPerHour, digits: 2)))
                            Text(L10n.format("≈%@ standard transcription hours / month", number(allowance.monthlyHours)))
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        .monospacedDigit()
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                }
            }

            if let pro = comparisonPlans.first(where: { $0.tier.rawValue == "pro" }),
               let proCredits = pro.monthlyBudgetCredits,
               let proAllowance = pro.transcriptionAllowance,
               let baseline, let baseCredits = baseline.monthlyBudgetCredits, baseCredits > 0,
               let baseAllowance = baseline.transcriptionAllowance {
                Divider()
                Text(L10n.format(
                    "Pro includes %@× the monthly credits, giving you about %@× Starter’s transcription time.",
                    number(Double(proCredits) / Double(baseCredits)),
                    number(proAllowance.multiplier(comparedTo: baseAllowance))
                ))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)

                let savings = proAllowance.rateReduction(comparedTo: baseAllowance)
                if savings > 0 {
                    Text(L10n.format("Pro uses about %@%% fewer credits per hour for standard transcription.", number(savings * 100, digits: 0)))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Onboarding.ink)
                }
            }

            Text(L10n.string("Estimates use all monthly credits for standard transcription only, without translation or subtitle splitting. Other cloud features share the same credit balance."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(width: AppTheme.zoomed(340), alignment: .leading)
    }

    private func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(AppLocalization.shared.activeLocale))
    }
}
#endif
