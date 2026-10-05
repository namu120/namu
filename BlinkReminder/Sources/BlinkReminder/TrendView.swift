import SwiftUI
import Charts
import BlinkCore

/// 일별 추이 창: 요약 타일, 하루 평균 깜빡임/분, 하루 활동 시간, 오늘 시간대별 추이.
struct TrendView: View {
    @EnvironmentObject var state: AppState
    @State private var periodDays = 30
    @State private var hoveredDay: Date?

    private struct DayPoint: Identifiable {
        var id: Date { date }
        var date: Date
        var rate: Double?          // 깜빡임/활동 1분
        var activeHours: Double
        var overlayTriggers: Int
        var notifications: Int
        var longestGap: Double
    }

    private static let targetRate = 15.0
    private static let lowRate = 10.0

    private var points: [DayPoint] {
        _ = state.statsRevision
        return state.stats.lastDays(periodDays, endingAt: Date()).map { item in
            let s = item.stats
            return DayPoint(date: item.date, rate: s.blinksPerMinute, activeHours: s.activeSeconds / 3600,
                            overlayTriggers: s.overlayTriggers, notifications: s.notifications, longestGap: s.longestGap)
        }
    }

    private var today: DayStats {
        _ = state.statsRevision
        return state.stats.day(Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summaryTiles
                dailyRateChart
                activeHoursChart
                hourlyChart
                footer
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    // MARK: 헤더 / 요약

    private var header: some View {
        HStack {
            Text("깜빡임 통계").font(.title2.weight(.semibold))
            Spacer()
            Picker("기간", selection: $periodDays) {
                Text("7일").tag(7)
                Text("30일").tag(30)
                Text("90일").tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private var summaryTiles: some View {
        let pts = points
        let rated = pts.compactMap(\.rate)
        let periodAvg = rated.isEmpty ? nil : rated.reduce(0, +) / Double(rated.count)
        let periodHours = pts.reduce(0) { $0 + $1.activeHours }
        return HStack(spacing: 12) {
            tile("오늘 깜빡임/분", value: fmtRate(today.blinksPerMinute), note: rateNote(today.blinksPerMinute))
            tile("오늘 활동 시간", value: fmtHours(today.activeSeconds / 3600), note: "얼굴이 보인 시간")
            tile("오늘 오버레이", value: "\(today.overlayTriggers)회", note: today.notifications > 0 ? "알림 \(today.notifications)회" : " ")
            tile("\(periodDays)일 평균", value: fmtRate(periodAvg), note: "활동 \(fmtHours(periodHours))")
        }
    }

    private func tile(_ title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: 차트 1: 하루 평균 깜빡임/분

    private var dailyRateChart: some View {
        let pts = points
        return VStack(alignment: .leading, spacing: 6) {
            chartTitle("하루 평균 깜빡임 (회/분)", hover: hoveredDay.flatMap { d in pts.first { $0.date == d } }.map(hoverRateText))
            Chart {
                ForEach(pts.filter { $0.rate != nil }) { p in
                    BarMark(x: .value("날짜", p.date, unit: .day), y: .value("회/분", p.rate ?? 0), width: barWidth)
                        .foregroundStyle((p.rate ?? 0) < Self.lowRate ? Color.orange : Color.accentColor)
                        .cornerRadius(3)
                        .opacity(hoveredDay == nil || hoveredDay == p.date ? 1 : 0.45)
                }
                RuleMark(y: .value("권장", Self.targetRate))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("권장 15회/분 이상").font(.caption2).foregroundStyle(.secondary)
                    }
                if let h = hoveredDay {
                    RuleMark(x: .value("선택", h, unit: .day)).foregroundStyle(.secondary.opacity(0.35))
                }
            }
            .chartXScale(domain: xDomain(pts))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) } }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
            .chartOverlay { proxy in hoverLayer(proxy: proxy, points: pts) }
            .frame(height: 180)
            if pts.allSatisfy({ $0.rate == nil }) {
                Text("아직 하루 1분 이상 기록된 날이 없습니다. 앱을 켜 두면 자동으로 쌓입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 차트 2: 하루 활동 시간

    private var activeHoursChart: some View {
        let pts = points
        return VStack(alignment: .leading, spacing: 6) {
            chartTitle("하루 활동 시간 (시간)", hover: hoveredDay.flatMap { d in pts.first { $0.date == d } }.map { p in
                "\(fmtDate(p.date)) · \(fmtHours(p.activeHours)) · 오버레이 \(p.overlayTriggers)회 · 최장 공백 \(Int(p.longestGap))초"
            })
            Chart {
                ForEach(pts.filter { $0.activeHours > 0 }) { p in
                    BarMark(x: .value("날짜", p.date, unit: .day), y: .value("시간", p.activeHours), width: barWidth)
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                        .cornerRadius(3)
                        .opacity(hoveredDay == nil || hoveredDay == p.date ? 1 : 0.45)
                }
                if let h = hoveredDay {
                    RuleMark(x: .value("선택", h, unit: .day)).foregroundStyle(.secondary.opacity(0.35))
                }
            }
            .chartXScale(domain: xDomain(pts))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) } }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
            .chartOverlay { proxy in hoverLayer(proxy: proxy, points: pts) }
            .frame(height: 120)
        }
    }

    // MARK: 차트 3: 오늘 시간대별

    private var hourlyChart: some View {
        let hours = today.hourly
        return VStack(alignment: .leading, spacing: 6) {
            chartTitle("오늘 시간대별 깜빡임 (회/분)", hover: nil)
            Chart {
                ForEach(hours.filter { $0.blinksPerMinute != nil }, id: \.hour) { h in
                    BarMark(x: .value("시", h.hour), y: .value("회/분", h.blinksPerMinute ?? 0))
                        .foregroundStyle((h.blinksPerMinute ?? 0) < Self.lowRate ? Color.orange : Color.accentColor)
                        .cornerRadius(3)
                }
                RuleMark(y: .value("권장", Self.targetRate))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: 0...24)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 24]) { v in AxisGridLine(); AxisValueLabel { if let i = v.as(Int.self) { Text("\(i)시") } } } }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
            .frame(height: 120)
            if hours.allSatisfy({ $0.blinksPerMinute == nil }) {
                Text("오늘은 아직 1분 이상 기록된 시간대가 없습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 푸터

    private var footer: some View {
        HStack {
            Text("데이터: \(state.stats.url.path)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("CSV로 내보내기…") { state.exportCSV() }
        }
    }

    // MARK: 보조

    private var barWidth: MarkDimension {
        periodDays <= 7 ? .fixed(36) : (periodDays <= 30 ? .fixed(12) : .fixed(4))
    }

    private func xDomain(_ pts: [DayPoint]) -> ClosedRange<Date> {
        let cal = Calendar.current
        let first = pts.first?.date ?? Date()
        let last = pts.last?.date ?? Date()
        return cal.date(byAdding: .hour, value: -12, to: first)!...cal.date(byAdding: .hour, value: 12, to: last)!
    }

    private func chartTitle(_ title: String, hover: String?) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let hover {
                Text(hover).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 마우스 위치의 날짜를 찾아 hoveredDay 에 넣는다 (툴팁은 차트 제목 줄에 표시).
    private func hoverLayer(proxy: ChartProxy, points: [DayPoint]) -> some View {
        GeometryReader { geo in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let plot = geo[proxy.plotAreaFrame]
                        guard let date: Date = proxy.value(atX: loc.x - plot.origin.x) else { hoveredDay = nil; return }
                        let day = Calendar.current.startOfDay(for: date)
                        hoveredDay = points.contains { $0.date == day } ? day : nil
                    case .ended:
                        hoveredDay = nil
                    }
                }
        }
    }

    private func hoverRateText(_ p: DayPoint) -> String {
        "\(fmtDate(p.date)) · \(fmtRate(p.rate)) · 활동 \(fmtHours(p.activeHours))"
    }

    private func rateNote(_ r: Double?) -> String {
        guard let r else { return "1분 이상 기록되면 표시" }
        if r >= Self.targetRate { return "좋아요, 권장 범위예요" }
        if r >= Self.lowRate { return "조금 적어요" }
        return "많이 적어요. 의식적으로 깜빡여요"
    }

    private func fmtRate(_ r: Double?) -> String { r.map { String(format: "%.1f", $0) } ?? "—" }
    private func fmtHours(_ h: Double) -> String {
        h < 1 ? String(format: "%.0f분", h * 60) : String(format: "%.1f시간", h)
    }
    private func fmtDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M/d (E)"
        return f.string(from: d)
    }
}
