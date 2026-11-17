import SwiftUI
import AppKit

struct Toast: Identifiable {
    enum Kind { case success, error, info }
    let id = UUID()
    var text: String
    var detail: String? = nil
    var kind: Kind = .success
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondTitle: String? = nil
    var second: (() -> Void)? = nil
}

extension Store {
    /// Shows a toast in the corner. Successes fade after 7s, errors stay until closed.
    @discardableResult
    func toast(_ text: String, _ kind: Toast.Kind = .success, detail: String? = nil,
               action: (String, () -> Void)? = nil, second: (String, () -> Void)? = nil) -> UUID {
        let t = Toast(text: text, detail: detail, kind: kind, actionTitle: action?.0, action: action?.1,
                      secondTitle: second?.0, second: second?.1)
        lastMessage = text
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            toasts.append(t)
            if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        }
        if kind == .success { Haptic.done() }
        if kind != .error {
            let id = t.id
            DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 6 : 9)) { [weak self] in self?.dismissToast(id) }
        }
        return t.id
    }

    func dismissToast(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { toasts.removeAll { $0.id == id } }
    }

    /// One click per 350ms across the app, so a fast double-click can't land on a second button.
    func allowClick() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastClick) < 0.35 { return false }
        lastClick = now
        return true
    }

    /// What's running right now, for the header and the menu bar.
    var activityText: String? {
        if let (id, text) = busy.first {
            let title = review?.items.first { $0.id == id }?.title ?? ""
            return title.isEmpty ? text : title + " · " + text
        }
        if organiseRun?.isRunning == true { return (organiseRun?.title ?? "Organising") + " · " + (organiseRun?.lines.last ?? "starting") }
        if rebuilding { return "Rebuilding the catalogue" }
        if askRun?.isRunning == true { return "Asking Claude" }
        return nil
    }
    var activityTab: Tab {
        if !busy.isEmpty { return .review }
        if organiseRun?.isRunning == true { return .runs }
        if rebuilding { return .sources }
        return .find
    }
}

enum Haptic {
    static func done() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    static func tap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
}

struct ToastStack: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(store.toasts) { t in ToastCard(toast: t) }
        }
        .padding(20)
        .frame(maxWidth: 460, alignment: .trailing)
    }
}

struct ToastCard: View {
    @EnvironmentObject var store: Store
    let toast: Toast
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: toast.kind == .error ? "exclamationmark.triangle.fill" : toast.kind == .info ? "info.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.kind == .error ? Theme.signal : toast.kind == .info ? Theme.lavender : Theme.accent)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(toast.text).font(Theme.sans(14, .medium)).foregroundStyle(Theme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = toast.detail {
                    Text(d).font(Theme.sans(12)).foregroundStyle(Theme.warmGrey).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if toast.actionTitle != nil || toast.secondTitle != nil {
                    HStack(spacing: 14) {
                        if let a = toast.actionTitle {
                            Button { toast.action?(); store.dismissToast(toast.id) } label: {
                                Text(a.uppercased()).font(Theme.mono(11)).tracking(0.9).foregroundStyle(Theme.accent)
                            }.buttonStyle(.plain)
                        }
                        if let b = toast.secondTitle {
                            Button { toast.second?(); store.dismissToast(toast.id) } label: {
                                Text(b.uppercased()).font(Theme.mono(11)).tracking(0.9).foregroundStyle(Theme.warmGrey)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button { store.dismissToast(toast.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
            }.buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2, lineWidth: 1))
        .overlay(alignment: .leading) {
            Rectangle().fill(toast.kind == .error ? Theme.signal : toast.kind == .info ? Theme.lavender : Theme.accent)
                .frame(width: 2).padding(.vertical, 8)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Header pill: what Stow is doing right now. Click to jump to it.
struct ActivityPill: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let text = store.activityText {
            Button { store.tab = store.activityTab } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                    Text(text).font(Theme.mono(11)).foregroundStyle(Theme.paper)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 12).frame(height: 28).frame(maxWidth: 360)
                .background(Capsule().fill(Theme.inset))
                .overlay(Capsule().stroke(Theme.accent.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

/// Pressed and disabled states for every Stow button.
struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
