// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Shared
import Storage
import Common

extension UIGestureRecognizer {
    func cancel() {
        if isEnabled {
            isEnabled = false
            isEnabled = true
        }
    }
}

// MARK: Delegate for animation completion notifications.
enum TabAnimationType {
    case addTab
    case removedNonLastTab
    case removedLastTab
    case updateTab
    case moveTab
}

protocol TabDisplayCompletionDelegate: AnyObject {
    func completedAnimation(for: TabAnimationType)
}

@objc
protocol TabSelectionDelegate: AnyObject {
    func didSelectTabAtIndex(_ index: Int)
}

protocol TopTabCellDelegate: AnyObject {
    func tabCellDidClose(_ cell: UICollectionViewCell)
}

protocol TabDisplayerDelegate: AnyObject {
    typealias TabCellIdentifier = String
    var tabCellIdentifier: TabCellIdentifier { get set }

    func focusSelectedTab()
    func cellFactory(for cell: UICollectionViewCell, using tab: Tab) -> UICollectionViewCell
}

enum TabDisplaySection: Int, CaseIterable {
    case inactiveTabs
    case regularTabs
}

enum TabDisplayType {
    case TabGrid
    case TopTabTray
}

// Regular tab order persistence for TabDisplayManager
struct TabDisplayOrder: Codable {
    static let defaults = UserDefaults(suiteName: AppInfo.sharedContainerIdentifier)!
    var regularTabUUID: [TabUUID] = []
}

class LegacyTabDisplayManager: NSObject, FeatureFlaggable {
    // MARK: - Variables
    private var performingChainedOperations = false
    var inactiveViewModel: LegacyInactiveTabViewModel?
    var isInactiveViewExpanded = false
    var dataStore = WeakList<Tab>()
    var operations = [(TabAnimationType, (() -> Void))]()
    var refreshStoreOperation: (() -> Void)?
    var tabDisplayType: TabDisplayType = .TabGrid
    var windowUUID: WindowUUID { return tabManager.windowUUID }
    private let tabManager: TabManager
    private let collectionView: UICollectionView

    private let tabReuseIdentifier: String
    private var hasSentInactiveTabShownEvent = false
    var profile: Profile
    var notificationCenter: NotificationProtocol
    var theme: Theme

    weak var tabDisplayCompletionDelegate: TabDisplayCompletionDelegate?
    private weak var tabDisplayerDelegate: TabDisplayerDelegate?
    private weak var cfrDelegate: InactiveTabsCFRProtocol?

    lazy var filteredTabs = [Tab]()
    var tabDisplayOrder = TabDisplayOrder()

    var shouldEnableInactiveTabs: Bool {
        return featureFlags.isFeatureEnabled(.inactiveTabs, checking: .buildAndUser)
    }

    var orderedTabs: [Tab] {
        return filteredTabs
    }

    private(set) var isPrivate = false

    private var isSelectedTabTypeEmpty: Bool {
        return isPrivate ? tabManager.privateTabs.isEmpty : tabManager.normalTabs.isEmpty
    }

    // Dragging on the collection view is either an 'active drag' where the item is moved, or
    // that the item has been long pressed on (and not moved yet), and this gesture recognizer
    // has been triggered
    var isDragging: Bool {
        return collectionView.hasActiveDrag || isLongPressGestureStarted
    }

    private var isLongPressGestureStarted: Bool {
        var started = false
        collectionView.gestureRecognizers?.forEach { recognizer in
            if let recognizer = recognizer as? UILongPressGestureRecognizer,
               recognizer.state == .began || recognizer.state == .changed {
                started = true
            }
        }
        return started
    }

    var shouldPresentUndoToastOnHomepage: Bool {
        guard !isPrivate else { return false }
        return tabManager.normalTabs.count == 1
    }

    func getRegularOrderedTabs() -> [Tab]? {
        // Get current order
        guard let tabDisplayOrderDecoded = TabDisplayOrder.decode() else { return nil }
        var decodedTabUUID = tabDisplayOrderDecoded.regularTabUUID
        guard !decodedTabUUID.isEmpty else { return nil }
        let filteredTabCopy: [Tab] = filteredTabs.map { $0 }
        var filteredTabUUIDs: [String] = filteredTabs.map { $0.tabUUID }
        var regularOrderedTabs: [Tab] = []

        // Remove any stale uuid from tab display order
        decodedTabUUID = decodedTabUUID.filter({ uuid in
            let shouldAdd = filteredTabUUIDs.contains(uuid)
            filteredTabUUIDs.removeAll { $0 == uuid }
            return shouldAdd
        })

        // Add missing uuid to tab display order from filtered tab
        decodedTabUUID.append(contentsOf: filteredTabUUIDs)

        // Get list of tabs corresponding to the uuids from tab display order
        decodedTabUUID.forEach { tabUUID in
            if let tabIndex = filteredTabCopy.firstIndex(where: { tab in
                tab.tabUUID == tabUUID
            }) {
                regularOrderedTabs.append(filteredTabCopy[tabIndex])
            }
        }

        return !regularOrderedTabs.isEmpty ? regularOrderedTabs : nil
    }

    func saveRegularOrderedTabs(from tabs: [Tab]) {
        let uuids: [String] = tabs.map { $0.tabUUID }
        tabDisplayOrder.regularTabUUID = uuids
        TabDisplayOrder.encode(tabDisplayOrder: tabDisplayOrder)
    }

    @discardableResult
    private func cancelDragAndGestures() -> Bool {
        let isActive = collectionView.hasActiveDrag || isLongPressGestureStarted
        collectionView.cancelInteractiveMovement()
        collectionView.endInteractiveMovement()

        // Long-pressing a cell to initiate dragging, but not actually moving the cell,
        // will not trigger the collectionView's internal 'interactive movement'
        // vars/funcs, and cancelInteractiveMovement() will not work. The gesture
        // recognizer needs to be cancelled in this case.
        collectionView.gestureRecognizers?.forEach { $0.cancel() }

        return isActive
    }

    init(collectionView: UICollectionView,
         tabManager: TabManager,
         tabDisplayer: TabDisplayerDelegate,
         reuseID: String,
         tabDisplayType: TabDisplayType,
         profile: Profile,
         cfrDelegate: InactiveTabsCFRProtocol? = nil,
         theme: Theme
    ) {
        self.collectionView = collectionView
        self.tabDisplayerDelegate = tabDisplayer
        self.tabManager = tabManager
        self.isPrivate = tabManager.selectedTab?.isPrivate ?? false
        self.tabReuseIdentifier = reuseID
        self.tabDisplayType = tabDisplayType
        self.profile = profile
        self.cfrDelegate = cfrDelegate
        self.notificationCenter = NotificationCenter.default
        self.theme = theme

        super.init()
        setupNotifications(forObserver: self, observing: [.DidTapUndoCloseAllTabToast])
        self.inactiveViewModel = LegacyInactiveTabViewModel(theme: theme)
        tabManager.addDelegate(self)
        register(self, forTabEvents: .didChangeURL, .didSetScreenshot)
        self.dataStore.removeAll()
        getTabsAndUpdateInactiveState { [weak self] tabsToDisplay in
            guard let self, !tabsToDisplay.isEmpty else { return }

            let defaultTabsValue = self.getRegularOrderedTabs() ?? tabsToDisplay
            let orderedRegularTabs = tabDisplayType == .TopTabTray ? tabsToDisplay : defaultTabsValue

            if self.getRegularOrderedTabs() == nil {
                self.saveRegularOrderedTabs(from: tabsToDisplay)
            }
            orderedRegularTabs.forEach {
                self.dataStore.insert($0)
            }
            self.collectionView.reloadData()
        }
    }

    private func tabsSetupHelper(filteredTabs: [Tab]) {
        self.filteredTabs = filteredTabs
    }

    private func setupFilteredTabs(tabsToBuildFrom: [Tab], completion: @escaping ([Tab]) -> Void) {
        tabsSetupHelper(filteredTabs: tabsToBuildFrom)
        completion(tabsToBuildFrom)
    }

    private func getTabsAndUpdateInactiveState(completion: @escaping ([Tab]) -> Void) {
        let allTabs = self.isPrivate ? tabManager.privateTabs : tabManager.normalTabs

        // We should not make a single tab inactive as that would be the selected tab
        guard !self.isPrivate, allTabs.count > 1 else {
            tabsSetupHelper(filteredTabs: allTabs)
            completion(allTabs)
            return
        }

        if shouldEnableInactiveTabs, let inactiveViewModel = inactiveViewModel {
            var selectedTab = tabManager.selectedTab
            // Make sure selected tab has latest time
            selectedTab?.lastExecutedTime = Date.now()

            // Special Case: When toggling from Private to Regular
            // mode none of the regular tabs are selected,
            // this is because toggling from one mode to another a user still
            // has to tap on a tab to select in order to fully switch modes
            if let firstTab = allTabs.first, firstTab.isPrivate != selectedTab?.isPrivate {
                selectedTab = mostRecentTab(inTabs: tabManager.normalTabs)
            }

            // update model
            inactiveViewModel.updateInactiveTabs(with: selectedTab, tabs: allTabs)

            // keep inactive tabs collapsed
            self.isInactiveViewExpanded = false
        }

        guard tabDisplayType == .TabGrid else {
            var filteredTabs = allTabs
            if shouldEnableInactiveTabs, let inactiveViewModel = inactiveViewModel {
                filteredTabs = inactiveViewModel.activeTabs
            }
            tabsSetupHelper(filteredTabs: filteredTabs)
            completion(filteredTabs)
            return
        }

        guard let inactiveViewModel = inactiveViewModel,
              shouldEnableInactiveTabs else {
            setupFilteredTabs(tabsToBuildFrom: tabManager.normalTabs,
                              completion: completion)
            return
        }

        setupFilteredTabs(tabsToBuildFrom: inactiveViewModel.activeTabs,
                          completion: completion)
    }

    func indexOfRegularTab(tab: Tab) -> Int? {
        return filteredTabs.firstIndex(of: tab)
    }

    func togglePrivateMode(isOn: Bool,
                           createTabOnEmptyPrivateMode: Bool,
                           shouldSelectMostRecentTab: Bool = false) {
        guard isPrivate != isOn else { return }

        isPrivate = isOn

        UserDefaults.standard.set(isPrivate, forKey: PrefsKeys.LastSessionWasPrivate)

        TelemetryWrapper.recordEvent(
            category: .action,
            method: .tap,
            object: .privateBrowsingButton,
            extras: ["is-private": isOn.description]
        )

        if createTabOnEmptyPrivateMode {
            // if private tabs is empty and we are transitioning to it add a tab
            if tabManager.privateTabs.isEmpty && isPrivate {
                let privateTabToSelect = tabManager.addTab(isPrivate: true)
                self.tabManager.selectTab(privateTabToSelect)
            }
        }

        if shouldSelectMostRecentTab {
            getTabsAndUpdateInactiveState { [weak self] tabsToDisplay in
                let tab = mostRecentTab(inTabs: tabsToDisplay) ?? tabsToDisplay.last
                if let tab = tab {
                    self?.tabManager.selectTab(tab)
                }
            }
        }

        refreshStore(evenIfHidden: false, shouldAnimate: true)

        let notificationObject = [Tab.privateModeKey: isPrivate]
        NotificationCenter.default.post(name: .TabsPrivacyModeChanged,
                                        object: notificationObject,
                                        userInfo: tabManager.windowUUID.userInfo)
    }

    /// Find the previously selected cell, which is still displayed as selected
    /// - Parameters:
    ///   - currentlySelected: The currently selected tab
    ///   - inSection: In which section should this tab be searched
    /// - Returns: The index path of the found previously selected tab
    private func indexOfCellDrawnAsPreviouslySelectedTab(currentlySelected: Tab?, inSection: Int) -> IndexPath? {
        guard let currentlySelected = currentlySelected else { return nil }

        for index in 0..<collectionView.numberOfItems(inSection: inSection) {
            guard let cell = collectionView.cellForItem(
                at: IndexPath(
                    row: index,
                    section: inSection
                )
            ) as? LegacyTabTrayCell,
                  cell.isSelectedTab,
                  let tab = dataStore.at(index),
                  tab != currentlySelected
            else { continue }

            return IndexPath(row: index, section: inSection)
        }

        return nil
    }

    func refreshStore(evenIfHidden: Bool = false,
                      shouldAnimate: Bool = false,
                      completion: (() -> Void)? = nil) {
        operations.removeAll()
        dataStore.removeAll()

        getTabsAndUpdateInactiveState { [weak self] tabsToDisplay in
            guard let self else { return }
            tabsToDisplay.forEach {
                self.dataStore.insert($0)
            }

            if shouldAnimate {
                UIView.transition(
                    with: self.collectionView,
                    duration: 0.3,
                    options: .transitionCrossDissolve,
                    animations: {
                        self.collectionView.reloadData()
                    }
                ) { finished in
                    if finished {
                        self.collectionView.reloadData()
                    }
                }
            } else {
                self.collectionView.reloadData()
            }

            if evenIfHidden {
                // reloadData() will reset the data for the collection view,
                // but if called when offscreen it will not render properly,
                // unless reloadItems is explicitly called on each item.
                // Avoid calling with evenIfHidden=true, as it can cause a blink effect as the cell is updated.
                // The cause of the blinking effect is unknown (and unusual).
                var indexPaths = [IndexPath]()
                for i in 0..<self.collectionView.numberOfItems(inSection: 0) {
                    indexPaths.append(IndexPath(item: i, section: 0))
                }
                self.collectionView.reloadItems(at: indexPaths)
            }

            self.tabDisplayerDelegate?.focusSelectedTab()
            completion?()
        }
    }

    /// Close tab action for Top tabs type
    func closeActionPerformed(forCell cell: UICollectionViewCell) {
        guard !isDragging else { return }

        guard let index = collectionView.indexPath(for: cell)?.item,
                let tab = dataStore.at(index) else { return }

        performCloseAction(for: tab)
    }

    /// Close tab action for Grid type
    func performCloseAction(for tab: Tab) {
        guard !isDragging else { return }

        getTabsAndUpdateInactiveState { [weak self] tabsToDisplay in
            guard let self else { return }
            // If it is the last tab of regular mode we automatically create an new tab
            if !self.isPrivate,
               tabsToDisplay.count == 1 {
                self.tabManager.removeTabs([tab])
                self.tabManager.selectTab(self.tabManager.addTab())
                return
            }

            self.tabManager.removeTab(tab)
        }
    }

    func undoCloseTab(tab: Tab, index: Int?) {
        tabManager.undoCloseTab()
        _ = profile.recentlyClosedTabs.popFirstTab()

        refreshStore { [weak self] in
            self?.updateCellFor(tab: tab, selectedTabChanged: true)
        }
    }

    // When using 'Close All', hide all the tabs so they don't animate their deletion individually
    func hideDisplayedTabs( completion: @escaping () -> Void) {
        let cells = collectionView.visibleCells

        UIView.animate(withDuration: 0.2,
                       animations: {
            cells.forEach {
                $0.alpha = 0
            }
        }, completion: { _ in
            cells.forEach {
                $0.alpha = 1
                $0.isHidden = true
            }
            completion()
        })
    }

    private func recordEventAndBreadcrumb(
        object: TelemetryWrapper.EventObject,
        method: TelemetryWrapper.EventMethod
    ) {
        let isTabTray = tabDisplayerDelegate as? LegacyGridTabViewController != nil
        let eventValue = isTabTray ? TelemetryWrapper.EventValue.tabTray : TelemetryWrapper.EventValue.topTabs
        TelemetryWrapper.recordEvent(category: .action, method: method, object: object, value: eventValue)
    }

    deinit {
        notificationCenter.removeObserver(self)
    }
}

// MARK: - UICollectionViewDataSource
extension LegacyTabDisplayManager: UICollectionViewDataSource {
    @objc
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard tabDisplayType != .TopTabTray else {
            return dataStore.count
        }

        switch TabDisplaySection(rawValue: section) {
        case .inactiveTabs:
            // Hide inactive tray if there are no inactive tabs
            guard let vm = inactiveViewModel, !vm.inactiveTabs.isEmpty else { return 0 }
            return shouldEnableInactiveTabs ? (isPrivate ? 0 : 1) : 0
        case .regularTabs:
            return dataStore.count
        case .none:
            return 0
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        return UICollectionReusableView()
    }

    @objc
    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        var cell = collectionView.dequeueReusableCell(withReuseIdentifier: self.tabReuseIdentifier, for: indexPath)
        if tabDisplayType == .TopTabTray {
            guard let tab = dataStore.at(indexPath.row) else { return cell }
            cell = tabDisplayerDelegate?.cellFactory(for: cell, using: tab) ?? cell
            return cell
        }

        switch TabDisplaySection(rawValue: indexPath.section) {
        case .inactiveTabs:
            if let inactiveCell = collectionView.dequeueReusableCell(
                withReuseIdentifier: LegacyInactiveTabCell.cellIdentifier,
                for: indexPath
            ) as? LegacyInactiveTabCell {
                inactiveCell.inactiveTabsViewModel = inactiveViewModel
                inactiveCell.applyTheme(theme: theme)
                inactiveCell.hasExpanded = isInactiveViewExpanded
                inactiveCell.delegate = self
                inactiveCell.tableView.reloadData()
                cell = inactiveCell
                if !hasSentInactiveTabShownEvent {
                    hasSentInactiveTabShownEvent = true
                    TelemetryWrapper.recordEvent(
                        category: .action,
                        method: .tap,
                        object: .inactiveTabTray,
                        value: .inactiveTabShown,
                        extras: nil
                    )
                }
            }

        case .regularTabs:
            guard let tab = dataStore.at(indexPath.row) else { return cell }
            cell = tabDisplayerDelegate?.cellFactory(for: cell, using: tab) ?? cell

        case .none:
            return cell
        }

        return cell
    }

    @objc
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        if tabDisplayType == .TopTabTray { return 1 }
        return TabDisplaySection.allCases.count
    }
}

// MARK: - InactiveTabsDelegate
extension LegacyTabDisplayManager: LegacyInactiveTabsDelegate {
    func closeInactiveTab(_ tab: Tab, index: Int) {
        tabManager.backupCloseTab = BackupCloseTab(
            tab: tab,
            restorePosition: index,
            isSelected: false)
        removeSingleInactiveTab(tab)

        cfrDelegate?.presentUndoSingleToast { [weak self] undoButtonPressed in
            guard undoButtonPressed, let closedTab = self?.tabManager.backupCloseTab else {
                TelemetryWrapper.recordEvent(category: .action,
                                             method: .tap,
                                             object: .inactiveTabTray,
                                             value: .inactiveTabSwipeClose,
                                             extras: nil)
                return
            }
            self?.undoDeleteInactiveTab(closedTab.tab, at: closedTab.restorePosition ?? 0)
        }
    }

    func didTapCloseInactiveTabs(tabsCount: Int) {
        // Haptic feedback for when a user closes all inactive tabs
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Hide inactive tabs and reload section to "simulate" deletion
        inactiveViewModel?.shouldHideInactiveTabs = true
        collectionView.reloadSections(IndexSet(integer: TabDisplaySection.inactiveTabs.rawValue))

        cfrDelegate?.presentUndoToast(tabsCount: tabsCount,
                                      completion: { [weak self] undoButtonPressed in
            undoButtonPressed ? self?.undoInactiveTabsClose() : self?.closeAllInactiveTabs()
        })
    }

    private func closeAllInactiveTabs() {
        guard let inactiveTabs = inactiveViewModel?.inactiveTabs,
              !inactiveTabs.isEmpty else { return }

        removeInactiveTabAndReloadView(tabs: inactiveTabs)
        TelemetryWrapper.recordEvent(category: .action,
                                     method: .tap,
                                     object: .inactiveTabTray,
                                     value: .inactiveTabCloseAllButton,
                                     extras: nil)
    }

    private func removeInactiveTabAndReloadView(tabs: [Tab]) {
        // Remove inactive tabs from tab manager
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.tabManager.removeTabs(tabs)
            let mostRecentTab = mostRecentTab(inTabs: self.tabManager.normalTabs) ?? self.tabManager.normalTabs.last
            self.tabManager.selectTab(mostRecentTab)
        }

        let allTabs = isPrivate ? tabManager.privateTabs : tabManager.normalTabs
        inactiveViewModel?.updateInactiveTabs(with: tabManager.selectedTab, tabs: allTabs)
        let indexPath = IndexPath(row: 0, section: TabDisplaySection.inactiveTabs.rawValue)

        // Refresh store when we have no inactive tabs in the list
        guard let inactiveVm = inactiveViewModel,
              !inactiveVm.inactiveTabs.isEmpty
        else {
            refreshStore()
            return
        }

        collectionView.reloadItems(at: [indexPath])
    }

    private func removeSingleInactiveTab(_ tab: Tab) {
        tabManager.removeTab(tab)
        collectionView.reloadSections(IndexSet(integer: TabDisplaySection.inactiveTabs.rawValue))
    }

    private func undoDeleteInactiveTab(_ tab: Tab, at index: Int) {
        tabManager.undoCloseTab()
        inactiveViewModel?.inactiveTabs.insert(tab, at: index)

        if inactiveViewModel?.inactiveTabs.count == 1 {
            toggleInactiveTabSection(hasExpanded: true)
        } else {
            collectionView.reloadSections(IndexSet(integer: TabDisplaySection.inactiveTabs.rawValue))
        }
    }

    private func undoInactiveTabsClose() {
        inactiveViewModel?.shouldHideInactiveTabs = false
        collectionView.reloadSections(IndexSet(integer: TabDisplaySection.inactiveTabs.rawValue))
    }

    func didSelectInactiveTab(tab: Tab?) {
        TelemetryWrapper.recordEvent(category: .action,
                                     method: .tap,
                                     object: .inactiveTabTray,
                                     value: .openInactiveTab,
                                     extras: nil)
        if let tabTray = tabDisplayerDelegate as? LegacyGridTabViewController {
            tabManager.selectTab(tab)
            tabTray.dismissTabTray()
        }
    }

    func toggleInactiveTabSection(hasExpanded: Bool) {
        let hasExpandedEvent: TelemetryWrapper.EventValue = hasExpanded ? .inactiveTabExpand : .inactiveTabCollapse
        TelemetryWrapper.recordEvent(
            category: .action,
            method: .tap,
            object: .inactiveTabTray,
            value: hasExpandedEvent,
            extras: nil
        )

        isInactiveViewExpanded = hasExpanded
        collectionView.reloadSections(IndexSet(integer: TabDisplaySection.inactiveTabs.rawValue))
        let indexPath = IndexPath(row: 0, section: TabDisplaySection.inactiveTabs.rawValue)
        collectionView.scrollToItem(at: indexPath, at: .top, animated: true)
    }

    func setupCFR(with view: UILabel) {
        cfrDelegate?.setupCFR(with: view)
    }

    func presentCFR() {
        cfrDelegate?.presentCFR()
    }
}

// MARK: - TabSelectionDelegate
extension LegacyTabDisplayManager: TabSelectionDelegate {
    func didSelectTabAtIndex(_ index: Int) {
        guard let tab = dataStore.at(index) else { return }
        getTabsAndUpdateInactiveState { [weak self] tabsToDisplay in
            if tabsToDisplay.contains(tab) {
                self?.tabManager.selectTab(tab)
            }
            TelemetryWrapper.recordEvent(category: .action, method: .press, object: .tab)
        }
    }
}

// MARK: - UIDropInteractionDelegate
extension LegacyTabDisplayManager: UIDropInteractionDelegate {
    func dropInteraction(
        _ interaction: UIDropInteraction,
        canHandle session: UIDropSession
    ) -> Bool {
        // Prevent tabs from being dragged and dropped onto the "New Tab" button.
        if let localDragSession = session.localDragSession,
           let item = localDragSession.items.first,
           item.localObject as? Tab != nil {
            return false
        }

        return session.canLoadObjects(ofClass: URL.self)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        performDrop session: UIDropSession
    ) {
        recordEventAndBreadcrumb(object: .url, method: .drop)

        _ = session.loadObjects(ofClass: URL.self) { urls in
            guard let url = urls.first else { return }

            self.tabManager.addTab(URLRequest(url: url), isPrivate: self.isPrivate)
        }
    }
}

// MARK: - UICollectionViewDragDelegate
extension LegacyTabDisplayManager: UICollectionViewDragDelegate {
    // This is called when the user has long-pressed on a cell, please note that
    // `collectionView.hasActiveDrag` is not true until the user's finger moves.
    // This problem is mitigated by checking the collectionView for activated long
    // press gesture recognizers.
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        let section = TabDisplaySection(rawValue: indexPath.section)
        guard tabDisplayType == .TopTabTray || section == .regularTabs else { return [] }
        guard let tab = dataStore.at(indexPath.item) else { return [] }

        // Don't store the URL in the item as dragging a tab near the screen edge will
        // prompt to open Safari with the URL
        let itemProvider = NSItemProvider()

        recordEventAndBreadcrumb(object: .tab, method: .drag)

        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = tab
        return [dragItem]
    }
}

// MARK: - UICollectionViewDropDelegate
extension LegacyTabDisplayManager: UICollectionViewDropDelegate {
    private func dragPreviewParameters(
        _ collectionView: UICollectionView,
        dragPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? TopTabCell else { return nil }
        let previewParams = UIDragPreviewParameters()

        let path = UIBezierPath(
            roundedRect: cell.selectedBackground.frame,
            cornerRadius: TopTabsUX.TabCornerRadius
        )
        previewParams.visiblePath = path

        return previewParams
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dragPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        return dragPreviewParameters(collectionView, dragPreviewParametersForItemAt: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        return dragPreviewParameters(collectionView, dragPreviewParametersForItemAt: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard collectionView.hasActiveDrag,
              let destinationIndexPath = coordinator.destinationIndexPath,
              let dragItem = coordinator.items.first?.dragItem,
              let tab = dragItem.localObject as? Tab,
              let sourceIndex = dataStore.index(of: tab) else { return }

        // This enforces that filtered tabs, and tabs manager are in sync
        if tab.isPrivate {
            filteredTabs = tabManager.privateTabs.filter { filteredTabs.contains($0) }
        } else {
            filteredTabs = tabManager.normalTabs.filter { filteredTabs.contains($0) }
        }

        recordEventAndBreadcrumb(object: .tab, method: .drop)

        coordinator.drop(dragItem, toItemAt: destinationIndexPath)

        self.tabManager.reorderTabs(isPrivate: self.isPrivate, fromIndex: sourceIndex, toIndex: destinationIndexPath.item)

        if let indexToRemove = filteredTabs.firstIndex(of: tab) {
            filteredTabs.remove(at: indexToRemove)
        }

        filteredTabs.insert(tab, at: destinationIndexPath.item)

        saveRegularOrderedTabs(from: filteredTabs)

        /// According to Apple's documentation the best place to make the changes to the collectionView
        /// and dataStore is during the completion call of performBatchUpdates
        updateWith(animationType: .moveTab) { [weak self] in
            self?.dataStore.removeAll()

            self?.filteredTabs.forEach {
                self?.dataStore.insert($0)
            }

            let section = self?.tabDisplayType == .TopTabTray ? 0 : TabDisplaySection.regularTabs.rawValue
            let start = IndexPath(row: sourceIndex, section: section)
            let end = IndexPath(row: destinationIndexPath.item, section: section)

            self?.collectionView.moveItem(at: start, to: end)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        let forbiddenOperation = UICollectionViewDropProposal(operation: .forbidden)
        guard let indexPath = destinationIndexPath else {
            return forbiddenOperation
        }

        let section = TabDisplaySection(rawValue: indexPath.section)
        guard tabDisplayType == .TopTabTray || section == .regularTabs else {
            return forbiddenOperation
        }

        // Forbidden if collection view isn't in the same mode as drop session
        guard let localDragSession = session.localDragSession,
              let item = localDragSession.items.first,
              let localObject = item.localObject as? Tab,
              localObject.isPrivate == self.isPrivate
        else {
            return forbiddenOperation
        }

        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }
}

extension LegacyTabDisplayManager: TabEventHandler {
    var tabEventWindowResponseType: TabEventHandlerWindowResponseType { return .singleWindow(windowUUID) }

    func tabDidSetScreenshot(_ tab: Tab, hasHomeScreenshot: Bool) {
        guard let indexPath = getIndexPath(tab: tab) else { return }
        refreshCell(atIndexPath: indexPath)
    }

    func tab(_ tab: Tab, didChangeURL url: URL) {
        guard let indexPath = getIndexPath(tab: tab) else { return }
        refreshCell(atIndexPath: indexPath)
    }

    private func getIndexPath(tab: Tab) -> IndexPath? {
        guard let index = dataStore.index(of: tab) else { return nil }
        let section = tabDisplayType == .TopTabTray ? 0 : TabDisplaySection.regularTabs.rawValue

        return IndexPath(row: index, section: section)
    }

    private func updateCellFor(tab: Tab, selectedTabChanged: Bool) {
        let selectedTab = tabManager.selectedTab

        updateWith(animationType: .updateTab) { [weak self] in
            guard let index = self?.dataStore.index(of: tab) else { return }
            let section = self?.tabDisplayType == .TopTabTray ? 0 : TabDisplaySection.regularTabs.rawValue

            var indexPaths = [IndexPath(row: index, section: section)]

            if selectedTabChanged {
                self?.tabDisplayerDelegate?.focusSelectedTab()

                // Append the previously selected tab to refresh it's state. Useful when the selected tab has change.
                // This method avoids relying on the state of the "previous" selected tab,
                // instead it iterates the displayed tabs to see which appears selected.
                if let previousSelectedIndexPath = self?.indexOfCellDrawnAsPreviouslySelectedTab(
                    currentlySelected: selectedTab,
                    inSection: section
                ) {
                    indexPaths.append(previousSelectedIndexPath)
                }
            }

            for indexPath in indexPaths {
                self?.refreshCell(atIndexPath: indexPath)

                // Due to https://github.com/mozilla-mobile/firefox-ios/issues/9526 - Refresh next cell to avoid two selected cells
                let nextTabIndex = IndexPath(row: indexPath.row + 1, section: indexPath.section)
                self?.refreshCell(atIndexPath: nextTabIndex, forceUpdate: false)
            }
        }
    }

    private func refreshCell(atIndexPath indexPath: IndexPath, forceUpdate: Bool = true) {
        guard let cell = collectionView.cellForItem(at: indexPath) as? LegacyTabTrayCell,
              let tab = dataStore.at(indexPath.row) else { return }

        // Only update from nextTabIndex if needed
        guard forceUpdate || cell.isSelectedTab else { return }

        let isSelected = tab == tabManager.selectedTab
        cell.configureLegacyCellWith(tab: tab,
                                     isSelected: isSelected,
                                     theme: theme)
    }

    func removeAllTabsFromView() {
        operations.removeAll()
        dataStore.removeAll()
        collectionView.reloadData()
    }
}

// MARK: - TabManagerDelegate
extension LegacyTabDisplayManager: TabManagerDelegate {
    func tabManager(
        _ tabManager: TabManager,
        didSelectedTabChange selected: Tab?,
        previous: Tab?,
        isRestoring: Bool
    ) {
        cancelDragAndGestures()

        if let selected = selected {
            // A tab can be re-selected during deletion
            let changed = selected != previous
            updateCellFor(tab: selected, selectedTabChanged: changed)
        }

        // Rather than using 'previous' Tab to deselect, just check if the selected tab
        // is different, and update the required cells. The refreshStore() cancels
        // pending operations are reloads data, so we don't want functions that rely on
        // any assumption of previous state of the view. Passing a previous tab (and
        // relying on that to redraw the previous tab as unselected) would be making
        // this assumption about the state of the view.
    }

    func tabManager(
        _ tabManager: TabManager,
        didAddTab tab: Tab,
        placeNextToParentTab: Bool,
        isRestoring: Bool
    ) {
        if cancelDragAndGestures() {
            refreshStore()
            return
        }

        guard tab.isPrivate == self.isPrivate else { return }

        updateWith(animationType: .addTab) { [unowned self] in
            let indexToPlaceTab = getIndexToPlaceTab(placeNextToParentTab: placeNextToParentTab)
            self.dataStore.insert(tab, at: indexToPlaceTab)
            let section = self.tabDisplayType == .TopTabTray ? 0 : TabDisplaySection.regularTabs.rawValue
            self.collectionView.insertItems(at: [IndexPath(row: indexToPlaceTab, section: section)])
        }
    }

    func getIndexToPlaceTab(placeNextToParentTab: Bool) -> Int {
        // Place new tab at the end by default unless it has been opened from parent tab
        var indexToPlaceTab = !dataStore.isEmpty ? dataStore.count : 0

        // Open a link from website next to it
        if placeNextToParentTab, let selectedTabUUID = tabManager.selectedTab?.tabUUID {
            let selectedTabIndex = dataStore.firstIndexDel { t in
                if let uuid = t.value?.tabUUID {
                    return uuid == selectedTabUUID
                }
                return false
            }

            if let selectedTabIndex = selectedTabIndex {
                indexToPlaceTab = selectedTabIndex + 1
            }
        }
        return indexToPlaceTab
    }

    func tabManager(_ tabManager: TabManager, didRemoveTab tab: Tab, isRestoring: Bool) {
        if cancelDragAndGestures() {
            refreshStore()
            return
        }

        let type = isSelectedTabTypeEmpty ? TabAnimationType.removedLastTab : TabAnimationType.removedNonLastTab

        updateWith(animationType: type) { [weak self] in
            guard let removed = self?.dataStore.remove(tab) else { return }
            let section = self?.tabDisplayType == .TopTabTray ? 0 : TabDisplaySection.regularTabs.rawValue
            self?.collectionView.deleteItems(at: [IndexPath(row: removed, section: section)])
        }
    }

    /* Function to take operations off the queue recursively, and perform them (i.e. performBatchUpdates) in sequence.
     If this func is called while it (or performBatchUpdates) is running, it returns immediately.

     The `refreshStore()` function will clear the queue and reload data, and the view will instantly
     match the tab manager. Therefore, don't put operations on the queue that depend on previous
     operations on the queue. In these cases, just check the current state on-demand in the
     operation (for example, don't assume that a previous tab is selected because that was the
     previous operation in queue).

     For app events where each operation should be animated for the user to see, performedChainedOperations()
     is the one to use, and for bulk updates where it is ok to just redraw the entire view with
     the latest state, use `refreshStore()`.
     */
    private func performChainedOperations() {
        guard !performingChainedOperations,
              let (type, operation) = operations.popLast()
        else { return }

        performingChainedOperations = true
        /// Fix crash related to bug from `collectionView.performBatchUpdates` when the
        /// collectionView is not visible the dataSource section/items differs from the actions to be perform
        /// which causes the crash
        collectionView.numberOfItems(inSection: 0)
        collectionView.performBatchUpdates({
            operation()
        }, completion: { [weak self] (done) in
            self?.performingChainedOperations = false
            self?.tabDisplayCompletionDelegate?.completedAnimation(for: type)
            self?.performChainedOperations()
        })
    }

    private func updateWith(animationType: TabAnimationType,
                            operation: (() -> Void)?) {
        if let op = operation {
            operations.insert((animationType, op), at: 0)
        }

        performChainedOperations()
    }

    func tabManagerDidRestoreTabs(_ tabManager: TabManager) {
        cancelDragAndGestures()
        refreshStore()

        // Need scrollToCurrentTab and not focusTab; these exact params needed to focus (without using async dispatch).
        (tabDisplayerDelegate as? TopTabsViewController)?.scrollToCurrentTab(false, centerCell: true)
    }

    func tabManagerDidAddTabs(_ tabManager: TabManager) {
        cancelDragAndGestures()
    }

    func tabManagerDidRemoveAllTabs(_ tabManager: TabManager, toast: ButtonToast?) {
        cancelDragAndGestures()
    }
}

extension LegacyTabDisplayManager: Notifiable {
    // MARK: - Notifiable protocol
    func handleNotifications(_ notification: Notification) {
        switch notification.name {
        case .DidTapUndoCloseAllTabToast:
            guard tabManager.windowUUID == notification.windowUUID else { return }
            refreshStore()
            collectionView.reloadData()
        default:
            break
        }
    }
}

extension TabDisplayOrder {
    static func decode() -> TabDisplayOrder? {
        if let tabDisplayOrder = TabDisplayOrder.defaults.object(forKey: PrefsKeys.KeyTabDisplayOrder) as? Data {
            do {
                let jsonDecoder = JSONDecoder()
                let order = try jsonDecoder.decode(TabDisplayOrder.self, from: tabDisplayOrder)
                return order
            } catch let error as NSError {
                DefaultLogger.shared.log("Error: Unable to decode tab display order",
                                         level: .warning,
                                         category: .tabs,
                                         description: error.debugDescription)
            }
        }
        return nil
    }

    static func encode(tabDisplayOrder: TabDisplayOrder?) {
        guard let tabDisplayOrder = tabDisplayOrder, !tabDisplayOrder.regularTabUUID.isEmpty else {
            TabDisplayOrder.defaults.removeObject(forKey: PrefsKeys.KeyTabDisplayOrder)
            return
        }
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(tabDisplayOrder) {
            TabDisplayOrder.defaults.set(encoded, forKey: PrefsKeys.KeyTabDisplayOrder)
        }
    }
}
