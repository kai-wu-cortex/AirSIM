import SwiftUI
import UIKit

struct SMSConversationTimelineView: UIViewControllerRepresentable {
    let messages: [SMSMessage]
    let selection: SMSMessageSelection
    let locale: Locale
    let onBeginSelection: (String) -> Void
    let onToggleSelection: (String) -> Void
    let onBeginTextSelection: () -> Void

    func makeUIViewController(context: Context) -> SMSConversationTimelineController {
        SMSConversationTimelineController(presentation: self)
    }

    func updateUIViewController(_ controller: SMSConversationTimelineController, context: Context) {
        controller.update(self)
    }
}

final class SMSConversationTimelineController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    private var presentation: SMSConversationTimelineView
    private var items: [SMSTimelineItem] = []
    private var dates: [String: String] = [:]
    private var heights: [String: (width: CGFloat, selecting: Bool, height: CGFloat)] = [:]
    private var collection: UICollectionView!
    private var observers: [NSObjectProtocol] = []
    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isAccessibilityElement = true
        return label
    }()
    private var selectedTextID: String?
    private enum MenuAction { case text(String), more(String) }
    private var pendingMenuAction: MenuAction?
    private var outsideTap: UITapGestureRecognizer?
    private var initializedPosition = false
    private var previousCollectionSize: CGSize = .zero
    private var applyingGeometryChange = false
    private var sizeAnchor: Anchor?
    private var restoringPosition = false
    private struct Anchor {
        let id: String?
        let distance: CGFloat
        let bottom: Bool
        let nearBottom: Bool
    }

    init(presentation: SMSConversationTimelineView) {
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .systemBackground
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .interactive
        collection.allowsSelection = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(SMSConversationCell.self, forCellWithReuseIdentifier: "message")
        collection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collection)
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collection.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collection.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedElsewhere(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        outsideTap = tap
        let center = NotificationCenter.default
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.significantTimeChangeNotification,
                     NSNotification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDates()
            })
        }
        observers.append(center.addObserver(forName: UIContentSizeCategory.didChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.refreshMetrics()
        })
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, self.selectedTextID != nil,
                      let editor = note.object as? UIView,
                      let window = self.viewIfLoaded?.window, editor.window === window,
                      editor is UITextField || (editor as? UITextView)?.isEditable == true else { return }
                self.endTextSelection()
            })
        }
        rebuildItems()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let outsideTap { view.window?.addGestureRecognizer(outsideTap) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        endTextSelection()
        if let outsideTap { outsideTap.view?.removeGestureRecognizer(outsideTap) }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func update(_ value: SMSConversationTimelineView) {
        let old = presentation
        presentation = value
        guard isViewLoaded else { return }
        let contentChanged = old.messages != value.messages
        let localeChanged = old.locale != value.locale
        let selectionChanged = old.selection != value.selection
        guard contentChanged || localeChanged || selectionChanged else { return }
        let anchor = captureAnchor()
        let previousLastID = items.last?.id
        if contentChanged || localeChanged || value.selection.isSelecting {
            endTextSelection()
        }
        if contentChanged || localeChanged {
            heights.removeAll(keepingCapacity: true)
            rebuildItems()
            collection.reloadData()
        } else {
            // Selection changes do not recreate attributed strings or date formatters.
            for case let cell as SMSConversationCell in collection.visibleCells {
                guard let id = cell.messageID else { continue }
                cell.updateSelection(isSelecting: value.selection.isSelecting,
                                     selected: value.selection.selectedIDs.contains(id))
            }
            if old.selection.isSelecting != value.selection.isSelecting {
                heights.removeAll(keepingCapacity: true)
                collection.collectionViewLayout.invalidateLayout()
            }
        }
        collection.layoutIfNeeded()
        let appended = previousLastID != items.last?.id
        if contentChanged && appended && anchor.nearBottom && !value.selection.isSelecting && selectedTextID == nil {
            scrollToBottom()
        } else {
            restore(anchor)
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard !applyingGeometryChange else { return }
        // Capture before constraints resize the collection, including changes
        // caused by a side bar with no change to the parent view's bounds.
        if initializedPosition, sizeAnchor == nil {
            sizeAnchor = captureAnchor()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !applyingGeometryChange else { return }
        let size = collection.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let changed = size != previousCollectionSize
        let widthChanged = size.width != previousCollectionSize.width
        let anchor = sizeAnchor
        previousCollectionSize = size
        sizeAnchor = nil
        guard !initializedPosition || changed else { return }

        applyingGeometryChange = true
        defer { applyingGeometryChange = false }
        if widthChanged {
            heights.removeAll(keepingCapacity: true)
            collection.collectionViewLayout.invalidateLayout()
        }
        collection.layoutIfNeeded()
        if !initializedPosition {
            initializedPosition = true
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    private func rebuildItems() {
        items = SMSConversationPresentation.timeline(presentation.messages)
        emptyLabel.text = L10n.t("暂无短信")
        emptyLabel.accessibilityLanguage = presentation.locale.identifier
        collection.backgroundView = items.isEmpty ? emptyLabel : nil
        dates.removeAll(keepingCapacity: true)
        let now = Date()
        for item in items where item.showsTimestamp {
            dates[item.id] = SMSConversationPresentation.timestamp(item.message.timestamp,
                                                                  relativeTo: now, locale: presentation.locale)
        }
    }

    private func refreshDates() {
        guard isViewLoaded else { return }
        let anchor = captureAnchor()
        endTextSelection()
        rebuildItems()
        heights.removeAll(keepingCapacity: true)
        collection.reloadData()
        collection.layoutIfNeeded()
        restore(anchor)
    }

    private func refreshMetrics() {
        guard isViewLoaded else { return }
        let anchor = captureAnchor()
        endTextSelection()
        heights.removeAll(keepingCapacity: true)
        collection.reloadData()
        collection.collectionViewLayout.invalidateLayout()
        collection.layoutIfNeeded()
        restore(anchor)
    }

    private func captureAnchor() -> Anchor {
        let distanceToBottom = collection.contentSize.height - collection.contentOffset.y - collection.bounds.height
            + collection.adjustedContentInset.bottom
        let canFollow = selectedTextID == nil && !presentation.selection.isSelecting
        let bottom = distanceToBottom <= 1 && canFollow
        let nearBottom = distanceToBottom < 80 && canFollow
        let first = collection.indexPathsForVisibleItems.sorted().first
        guard let first, items.indices.contains(first.item),
              let frame = collection.layoutAttributesForItem(at: first)?.frame else {
            return Anchor(id: nil, distance: 0, bottom: bottom, nearBottom: nearBottom)
        }
        return Anchor(id: items[first.item].id, distance: frame.minY - collection.contentOffset.y,
                      bottom: bottom, nearBottom: nearBottom)
    }

    private func restore(_ anchor: Anchor) {
        guard !restoringPosition else { return }
        restoringPosition = true
        defer { restoringPosition = false }
        if anchor.bottom && !presentation.selection.isSelecting && selectedTextID == nil {
            scrollToBottom()
        } else if let id = anchor.id, let index = items.firstIndex(where: { $0.id == id }),
                  let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
            setOffset(frame.minY - anchor.distance)
        }
    }

    private func setOffset(_ y: CGFloat) {
        let minimum = -collection.adjustedContentInset.top
        let maximum = max(minimum, collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom)
        collection.setContentOffset(CGPoint(x: 0, y: min(maximum, max(minimum, y))), animated: false)
    }

    private func scrollToBottom() { setOffset(collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom) }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "message", for: indexPath) as! SMSConversationCell
        let item = items[indexPath.item]
        cell.configure(item, date: dates[item.id], locale: presentation.locale,
                       isSelecting: presentation.selection.isSelecting,
                       selected: presentation.selection.selectedIDs.contains(item.id))
        cell.onCopy = { [weak self] in self?.copyMessage(item.id) }
        cell.onSelectText = { [weak self] in self?.beginTextSelection(item.id) }
        cell.onMore = { [weak self] in self?.beginMessageSelection(item.id) }
        cell.onToggle = { [weak self] in self?.presentation.onToggleSelection(item.id) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let item = items[indexPath.item]
        let width = collectionView.bounds.width
        if let cached = heights[item.id], cached.width == width, cached.selecting == presentation.selection.isSelecting {
            return CGSize(width: width, height: cached.height)
        }
        let height = SMSConversationCell.height(for: item, date: dates[item.id], width: width,
                                               selecting: presentation.selection.isSelecting)
        heights[item.id] = (width, presentation.selection.isSelecting, height)
        return CGSize(width: width, height: height)
    }


    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !presentation.selection.isSelecting, selectedTextID == nil,
              let cell = collectionView.cellForItem(at: indexPath) as? SMSConversationCell,
              cell.bubble.bubblePath().contains(collectionView.convert(point, to: cell.bubble)) else { return nil }
        endTextSelection()
        let id = items[indexPath.item].id
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: L10n.t("复制"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyMessage(id) },
                UIAction(title: L10n.t("选择文本"), image: UIImage(systemName: "text.cursor")) { [weak self] _ in self?.pendingMenuAction = .text(id) },
                UIAction(title: L10n.t("更多…"), image: UIImage(systemName: "ellipsis.circle")) { [weak self] _ in self?.pendingMenuAction = .more(id) }
            ])
        }
    }

    func collectionView(_ collectionView: UICollectionView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        preview(configuration)
    }

    func collectionView(_ collectionView: UICollectionView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        preview(configuration)
    }

    private func preview(_ configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? String,
              let index = items.firstIndex(where: { $0.id == id }),
              let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? SMSConversationCell else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = cell.bubble.bubblePath()
        return UITargetedPreview(view: cell.bubble, parameters: parameters)
    }

    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionAnimating?) {
        let finish = { [weak self] in
            guard let self else { return }
            let action = self.pendingMenuAction
            self.pendingMenuAction = nil
            switch action {
            case .text(let id): self.beginTextSelection(id)
            case .more(let id): self.beginMessageSelection(id)
            case nil: break
            }
        }
        if let animator { animator.addCompletion(finish) } else { finish() }
    }

    private func copyMessage(_ id: String) {
        guard let message = items.first(where: { $0.id == id })?.message else { return }
        UIPasteboard.general.string = message.content
    }

    private func beginMessageSelection(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        endTextSelection()
        presentation.onBeginSelection(id)
    }

    private func beginTextSelection(_ id: String) {
        guard !presentation.selection.isSelecting,
              let index = items.firstIndex(where: { $0.id == id }),
              let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? SMSConversationCell,
              cell.messageID == id else { return }
        endTextSelection()
        presentation.onBeginTextSelection()
        selectedTextID = id
        cell.beginTextSelection()
    }

    private func endTextSelection() {
        selectedTextID = nil
        for case let cell as SMSConversationCell in collection.visibleCells { cell.endTextSelection() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { endTextSelection() }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let cell = cell as? SMSConversationCell, cell.messageID == selectedTextID { endTextSelection() }
    }

    @objc private func tappedElsewhere(_ recognizer: UITapGestureRecognizer) {
        guard let id = selectedTextID else { return }
        let point = recognizer.location(in: collection)
        if let path = collection.indexPathForItem(at: point),
           let cell = collection.cellForItem(at: path) as? SMSConversationCell,
           cell.messageID == id, cell.bubble.frame.contains(collection.convert(point, to: cell.contentView)) { return }
        endTextSelection()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !presentation.selection.isSelecting, let id = selectedTextID else { return false }
        if let index = items.firstIndex(where: { $0.id == id }),
           let cell = collection.cellForItem(at: IndexPath(item: index, section: 0)) as? SMSConversationCell,
           cell.containsTextSelectionTouch(touch) { return false }
        return true
    }
}

/// Context-bound codes used only for bubble highlighting; no backend field is required.
enum SMSCodeHighlight {
    static func renderedBody(in text: String, outgoing: Bool) -> (text: NSAttributedString, code: String)? {
        guard let match = match(in: text) else { return nil }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: outgoing ? UIColor.white : UIColor.label])
        attributed.addAttributes([.font: UIFont.preferredFont(forTextStyle: .headline),
            .backgroundColor: UIColor.systemYellow.withAlphaComponent(0.22),
            .link: URL(string: "airsim-code://copy/" + match.code)!], range: match.range)
        return (attributed, match.code)
    }
    static func match(in text: String) -> (code: String, range: NSRange)? {
        let keyword = #"(?:验证码|校验码|动态码|确认码|verification\s+code|security\s+code|one[- ]time(?:\s+(?:code|password))?|(?<![A-Za-z])otp(?![A-Za-z])|(?<![A-Za-z])code(?![A-Za-z]))"#
        let patterns = [keyword + #"([^0-9\r\n]{0,24})(?<![0-9])([0-9]{4,8})(?![0-9])"#,
                        #"(?<![0-9])([0-9]{4,8})(?![0-9])([^0-9\r\n]{0,16})"# + keyword]
        let full = NSRange(text.startIndex..., in: text)
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: full) {
                let codeRange = match.range(at: index == 0 ? 2 : 1)
                let gapRange = match.range(at: index == 0 ? 1 : 2)
                guard let code = Range(codeRange, in: text), let gap = Range(gapRange, in: text),
                      text[gap].range(of: #"订单|物流|运单|order|tracking"#, options: [.regularExpression, .caseInsensitive]) == nil else { continue }
                return (String(text[code]), codeRange)
            }
        }
        return nil
    }
}

private final class SMSConversationCell: UICollectionViewCell, UIEditMenuInteractionDelegate, UITextViewDelegate, UIContextMenuInteractionDelegate {
    private(set) var messageID: String?
    let bubble = SMSBubbleView()
    private let body = SMSReadOnlyTextView()
    private let dateLabel = UILabel()
    private let detailLabel = UILabel()
    private let check = UIImageView()
    private var item: SMSTimelineItem?
    private var highlightedCode: String?
    private var selecting = false
    private var measuredWidth: CGFloat = 0
    private var measuredSelecting = false
    private var measuredBubbleWidth: CGFloat = 0
    private var measuredDateHeight: CGFloat = 0
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private lazy var selectionTap = UITapGestureRecognizer(target: self, action: #selector(toggleFromTap(_:)))
    var onCopy: (() -> Void)?
    var onSelectText: (() -> Void)?
    var onMore: (() -> Void)?
    var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(dateLabel)
        contentView.addSubview(bubble)
        bubble.addSubview(body)
        contentView.addSubview(detailLabel)
        contentView.addSubview(check)
        dateLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .secondaryLabel
        dateLabel.textAlignment = .center
        dateLabel.numberOfLines = 0
        detailLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        body.backgroundColor = .clear
        body.delegate = self
        body.isEditable = false
        body.isSelectable = true
        body.isScrollEnabled = false
        body.textContainerInset = .zero
        body.textContainer.lineFragmentPadding = 0
        body.dataDetectorTypes = [.link, .phoneNumber]
        body.adjustsFontForContentSizeCategory = true
        body.addInteraction(editMenu)
        bubble.addInteraction(UIContextMenuInteraction(delegate: self))
        check.contentMode = .scaleAspectFit
        isAccessibilityElement = false
        contentView.addGestureRecognizer(selectionTap)
        selectionTap.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        endTextSelection()
        messageID = nil
        item = nil
        highlightedCode = nil
        pendingContextAction = nil
        onCopy = nil
        onSelectText = nil
        onMore = nil
        onToggle = nil
    }

    func configure(_ item: SMSTimelineItem, date: String?, locale: Locale, isSelecting: Bool, selected: Bool) {
        endTextSelection()
        self.item = item
        measuredWidth = 0
        messageID = item.id
        body.attributedText = nil
        body.font = UIFont.preferredFont(forTextStyle: .body)
        body.text = item.message.content
        body.textAlignment = .natural
        body.accessibilityLanguage = locale.identifier
        let outgoing = item.message.isOutgoing
        body.accessibilityHint = outgoing ? L10n.t("已发送") : nil
        body.textColor = outgoing ? .white : .label
        highlightedCode = nil
        if let highlighted = SMSCodeHighlight.renderedBody(in: item.message.content, outgoing: outgoing) {
            body.attributedText = highlighted.text
            highlightedCode = highlighted.code
        }
        body.linkTextAttributes = [.foregroundColor: outgoing ? UIColor.white : UIColor.link,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue]
        bubble.outgoing = outgoing
        bubble.hasTail = item.showsTail
        dateLabel.text = date
        dateLabel.isHidden = !item.showsTimestamp
        var details: [String] = []
        details.append(item.message.simDeliveryLabel)
        if outgoing && item.showsTail { details.append(L10n.t("已发送")) }
        detailLabel.text = details.joined(separator: " · ")
        detailLabel.isHidden = details.isEmpty
        detailLabel.textAlignment = outgoing ? .right : .left
        updateSelection(isSelecting: isSelecting, selected: selected)
    }

    func updateSelection(isSelecting: Bool, selected: Bool) {
        selecting = isSelecting
        selectionTap.isEnabled = isSelecting
        check.isHidden = !isSelecting
        check.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        check.tintColor = selected ? .systemBlue : .systemGray3
        body.isUserInteractionEnabled = !isSelecting
        body.isAccessibilityElement = !isSelecting
        isAccessibilityElement = isSelecting
        if isSelecting {
            endTextSelection()
            accessibilityLabel = [dateLabel.text, body.text, detailLabel.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            accessibilityTraits = selected ? [.button, .selected] : .button
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: L10n.t(selected ? "取消选择" : "选择短信")) { [weak self] _ in self?.onToggle?(); return true }]
        } else {
            accessibilityCustomActions = nil
            body.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: L10n.t("复制")) { [weak self] _ in self?.onCopy?(); return true },
                UIAccessibilityCustomAction(name: L10n.t("选择文本")) { [weak self] _ in self?.onSelectText?(); return true },
                UIAccessibilityCustomAction(name: L10n.t("更多…")) { [weak self] _ in self?.onMore?(); return true }
            ]
        }
        setNeedsLayout()
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                  in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        guard URL.scheme == "airsim-code", let code = highlightedCode,
              URL.lastPathComponent == code else { return true }
        UIPasteboard.general.string = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return false
    }

    private var pendingContextAction: (() -> Void)?

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !selecting, !body.textSelectionEnabled, bubble.bubblePath().contains(location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = []
            if let code = self.highlightedCode {
                actions.append(UIAction(title: L10n.t("复制验证码"), image: UIImage(systemName: "number")) { _ in
                    UIPasteboard.general.string = code
                })
            }
            actions += [
                UIAction(title: L10n.t("复制"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.onCopy?() },
                UIAction(title: L10n.t("选择文本"), image: UIImage(systemName: "text.cursor")) { [weak self] _ in self?.pendingContextAction = self?.onSelectText },
                UIAction(title: L10n.t("更多…"), image: UIImage(systemName: "ellipsis.circle")) { [weak self] _ in self?.pendingContextAction = self?.onMore }
            ]
            return UIMenu(children: actions)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        let action = pendingContextAction
        pendingContextAction = nil
        if let animator { animator.addCompletion { action?() } } else { action?() }
    }

    @objc private func toggleFromTap(_ recognizer: UITapGestureRecognizer) {
        guard selecting, recognizer.location(in: contentView).y >= bubble.frame.minY else { return }
        onToggle?()
    }

    override func accessibilityActivate() -> Bool {
        guard selecting else { return super.accessibilityActivate() }
        onToggle?()
        return true
    }

    private static func bubbleWidth(for text: String, width: CGFloat, selecting: Bool) -> CGFloat {
        let maximum = max(40, min(width * 0.80, width - (selecting ? 72 : 40)))
        let font = UIFont.preferredFont(forTextStyle: .body)
        let rect = (text as NSString).boundingRect(with: CGSize(width: maximum - 28, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: font], context: nil)
        return min(maximum, max(44, ceil(rect.width) + 28))
    }

    private static func dateHeight(for date: String?, width: CGFloat) -> CGFloat {
        guard let date else { return 0 }
        let rect = (date as NSString).boundingRect(with: CGSize(width: max(1, width - 48), height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)], context: nil)
        return ceil(rect.height) + 24
    }

    static func height(for item: SMSTimelineItem, date: String?, width: CGFloat, selecting: Bool) -> CGFloat {
        let bubbleWidth = Self.bubbleWidth(for: item.message.content, width: width, selecting: selecting)
        let font = UIFont.preferredFont(forTextStyle: .body)
        let rect = (item.message.content as NSString).boundingRect(with: CGSize(width: bubbleWidth - 28, height: .greatestFiniteMagnitude),
                                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                                  attributes: [.font: font], context: nil)
        let dateHeight = Self.dateHeight(for: date, width: width)
        let detailHeight: CGFloat = ceil(UIFont.preferredFont(forTextStyle: .caption2).lineHeight) + 5
        return dateHeight + max(font.lineHeight, ceil(rect.height)) + 20 + detailHeight + (item.showsTail ? 10 : 3)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let item else { return }
        let width = contentView.bounds.width
        if measuredWidth != width || measuredSelecting != selecting {
            measuredWidth = width
            measuredSelecting = selecting
            measuredBubbleWidth = Self.bubbleWidth(for: item.message.content, width: width, selecting: selecting)
            measuredDateHeight = Self.dateHeight(for: dateLabel.text, width: width)
        }
        let dateHeight = measuredDateHeight
        dateLabel.frame = CGRect(x: 24, y: 8, width: max(0, width - 48), height: max(0, dateHeight - 16))
        let bubbleWidth = measuredBubbleWidth
        let detailHeight: CGFloat = detailLabel.isHidden ? 0 : ceil(detailLabel.font.lineHeight) + 5
        let bottom: CGFloat = item.showsTail ? 10 : 3
        let bubbleHeight = contentView.bounds.height - dateHeight - detailHeight - bottom
        let left: CGFloat = selecting ? 48 : 16
        let x = item.message.isOutgoing ? max(left, width - 16 - bubbleWidth) : left
        bubble.frame = CGRect(x: x, y: dateHeight, width: bubbleWidth, height: bubbleHeight)
        body.frame = bubble.bounds.insetBy(dx: 14, dy: 10)
        // Keep the receiving/sending line readable even for a one-character bubble.
        let detailWidth = max(0, width - left - 16)
        detailLabel.frame = CGRect(x: left, y: bubble.frame.maxY + 3, width: detailWidth, height: max(0, detailHeight - 3))
        check.frame = CGRect(x: 12, y: bubble.frame.midY - 12, width: 24, height: 24)
    }

    func containsTextSelectionTouch(_ touch: UITouch) -> Bool {
        guard let touchedView = touch.view else { return false }
        return touchedView.isDescendant(of: body)
    }

    func beginTextSelection() {
        guard !selecting else { return }
        body.textSelectionEnabled = true
        body.becomeFirstResponder()
        body.selectAll(nil)
        let range = body.selectedTextRange
        let rect = range.map { body.firstRect(for: $0) } ?? body.bounds
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: messageID as NSString?, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    func endTextSelection() {
        editMenu.dismissMenu()
        body.selectedTextRange = nil
        body.resignFirstResponder()
        body.textSelectionEnabled = false
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard body.textSelectionEnabled else { return nil }
        return UIMenu(children: suggestedActions)
    }
}

private final class SMSReadOnlyTextView: UITextView {
    var textSelectionEnabled = false
    override var canBecomeFirstResponder: Bool { textSelectionEnabled }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer && !textSelectionEnabled { return false }
        if let tap = gestureRecognizer as? UITapGestureRecognizer,
           tap.numberOfTapsRequired > 1 && !textSelectionEnabled { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard textSelectionEnabled else { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

private final class SMSBubbleView: UIView {
    var outgoing = false { didSet { if oldValue != outgoing { needsPath = true; setNeedsLayout() } } }
    var hasTail = false { didSet { if oldValue != hasTail { needsPath = true; setNeedsLayout() } } }
    private let shape = CAShapeLayer()
    private var needsPath = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        shape.actions = ["path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.insertSublayer(shape, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bubblePath() -> UIBezierPath {
        let inset: CGFloat = hasTail ? 5 : 0
        let rect = bounds.inset(by: UIEdgeInsets(top: 0, left: outgoing ? 0 : inset, bottom: 0, right: outgoing ? inset : 0))
        let path = UIBezierPath(roundedRect: rect, cornerRadius: min(19, rect.height / 2))
        if hasTail {
            let tail = UIBezierPath()
            if outgoing {
                tail.move(to: CGPoint(x: rect.maxX - 12, y: rect.maxY - 15))
                tail.addQuadCurve(to: CGPoint(x: bounds.maxX, y: rect.maxY), controlPoint: CGPoint(x: rect.maxX - 1, y: rect.maxY - 1))
                tail.addQuadCurve(to: CGPoint(x: rect.maxX - 18, y: rect.maxY - 5), controlPoint: CGPoint(x: rect.maxX - 8, y: rect.maxY + 1))
            } else {
                tail.move(to: CGPoint(x: rect.minX + 12, y: rect.maxY - 15))
                tail.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY), controlPoint: CGPoint(x: rect.minX + 1, y: rect.maxY - 1))
                tail.addQuadCurve(to: CGPoint(x: rect.minX + 18, y: rect.maxY - 5), controlPoint: CGPoint(x: rect.minX + 8, y: rect.maxY + 1))
            }
            tail.close()
            path.append(outgoing ? tail : tail.reversing())
        }
        return path
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsPath || shape.frame != bounds {
            shape.frame = bounds
            shape.path = bubblePath().cgPath
            shape.fillColor = (outgoing ? UIColor.systemGreen : UIColor.systemGray5).resolvedColor(with: traitCollection).cgColor
            needsPath = false
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            needsPath = true
            setNeedsLayout()
        }
    }
}
