import SwiftUI
import WidgetKit

struct AirSIMDeviceWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AirSIMWidgetSnapshot
}
struct AirSIMDeviceWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AirSIMDeviceWidgetEntry {
        .init(date: Date(), snapshot: .preview())
    }
    func getSnapshot(in context: Context, completion: @escaping (AirSIMDeviceWidgetEntry) -> Void) {
        completion(.init(date: Date(), snapshot: context.isPreview ? .preview() : AirSIMWidgetStore().load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AirSIMDeviceWidgetEntry>) -> Void) {
        let now = Date(), snapshot = AirSIMWidgetStore().load()
        let entries = ([now] + snapshot.expirationDates(after: now)).map {
            AirSIMDeviceWidgetEntry(date: $0, snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }
}
struct AirSIMDeviceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AirSIMWidgetSnapshot.kind, provider: AirSIMDeviceWidgetProvider()) { entry in
            AirSIMDeviceWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("安卓设备与最近通话")
        .description("查看最近同步的连接状态，快速打开拨号、短信与通讯录。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
private struct AirSIMDeviceWidgetEntryView: View {
    let entry: AirSIMDeviceWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        } else {
            content.padding(family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular ? 0 : 16)
                .background(family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular
                            ? Color.clear : Color(uiColor: .systemBackground))
        }
    }
    private var content: some View {
        AirSIMDeviceWidgetView(snapshot: entry.snapshot, date: entry.date, family: family)
    }
}
