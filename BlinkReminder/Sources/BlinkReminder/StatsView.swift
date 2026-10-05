import SwiftUI
import Charts
import BlinkCore

struct StatsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            metrics
            chart
            overlayBar
            if state.settings.showDebug { debugPanel }
            Divider()
            buttons
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: 섹션

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(state.status.tint).frame(width: 9, height: 9)
            Text(state.status.text).font(.callout).lineLimit(2)
            Spacer()
            Text("\(state.sessionMinutes)분째").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 0) {
            metric(title: "최근 1분", value: "\(state.blinksLastMinute)", unit: "회",
                   color: state.blinksLastMinute < 10 && state.sessionMinutes >= 1 ? .orange : .primary)
            metric(title: "10분 평균", value: String(format: "%.0f", state.blinksPer10MinAvg), unit: "회/분")
            metric(title: "마지막", value: String(format: "%.0f", state.secondsSinceBlink), unit: "초 전")
            metric(title: "최장 공백", value: String(format: "%.0f", state.longestGap), unit: "초")
        }
    }

    private func metric(title: String, value: String, unit: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(color)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("최근 30분 · 분당 깜빡임").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("세션 \(state.sessionTotal)회 · 오버레이 \(state.overlayTriggers)회")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(Array(state.history.enumerated()), id: \.offset) { item in
                    BarMark(
                        x: .value("분", item.offset - state.history.count + 1),
                        y: .value("회", item.element)
                    )
                    .foregroundStyle(item.element < 10 ? Color.orange.gradient : Color.accentColor.gradient)
                }
                RuleMark(y: .value("권장", 15))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("권장 15+").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .frame(height: 90)
        }
    }

    private var overlayBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("어두워지기까지").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(overlayText).font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(state.overlayProgress > 0 ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * timerFraction)
                }
            }
            .frame(height: 6)
        }
    }

    /// LIMIT 까지는 파란색으로 차오르고, 그 뒤 RAMP 동안은 주황색으로 오버레이 진행도를 보여준다.
    private var timerFraction: CGFloat {
        if state.overlayProgress > 0 { return CGFloat(state.overlayProgress) }
        guard state.status == .watching, state.settings.limitSeconds > 0 else { return 0 }
        return CGFloat(min(1, state.secondsSinceBlink / state.settings.limitSeconds))
    }

    private var overlayText: String {
        if state.overlayProgress > 0 {
            return String(format: "오버레이 %.0f%%", state.overlayAlpha / max(state.settings.maxAlpha, 0.01) * 100)
        }
        guard state.status == .watching else { return "—" }
        return String(format: "%.0f초 남음", max(0, state.settings.limitSeconds - state.secondsSinceBlink))
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("디버그").font(.caption).foregroundStyle(.secondary)
            Text("EAR L \(fmt(state.debug.leftEAR))  R \(fmt(state.debug.rightEAR))  →  감김 \(fmt(state.debug.score))   face=\(state.debug.faceFound ? 1 : 0)")
                .font(.system(.caption, design: .monospaced))
            Text(String(format: "기준: 뜸 ≥ %.2f · 감김 ≤ %.2f · 히스테리시스 >%.2f / <%.2f",
                        state.settings.earOpen, state.settings.earClosed,
                        state.settings.closeThreshold, state.settings.openThreshold))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ v: Double?) -> String {
        v.map { String(format: "%.2f", $0) } ?? "----"
    }

    private var buttons: some View {
        HStack {
            Button(state.paused ? "재개" : "일시정지") { state.togglePause() }
                .keyboardShortcut("p")
            Button("통계…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "trends")
            }
            .keyboardShortcut("t")
            Spacer()
            settingsButton
            Button("종료") { state.quit() }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Text("설정…") }
                .simultaneousGesture(TapGesture().onEnded { NSApplication.shared.activate(ignoringOtherApps: true) })
                .keyboardShortcut(",")
        } else {
            Button("설정…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")
        }
    }
}
