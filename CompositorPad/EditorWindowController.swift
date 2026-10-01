import UIKit
import UniformTypeIdentifiers

/// A window of the iPad app, laid out as the Mac's window is: a toolbar with the projects as tabs and the zoom
/// controls at its end, the tools down the left, and the canvas. Each tab is a document of its own, saved as it
/// changes; a window can hold several, and several windows can be open. It sits in a navigation controller for its
/// bar, which is the Mac's toolbar here.
final class EditorWindowController: UIViewController, UIDocumentPickerDelegate {
    static let restorationActivityType = "com.wonderassembly.compositor.ipad.window"
    /// Every window's controller, so a project already open in one is brought forward rather than opened twice.
    private static let controllers = NSHashTable<EditorWindowController>.weakObjects()

    private(set) var tabs: [EditorTab] = []
    private var activeID: UUID?
    var activeTab: EditorTab? { tabs.first { $0.id == activeID } }

    private let tabStrip = TabStripView()
    private lazy var newTabItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.newCanvasTab(nil) })
        item.accessibilityLabel = "New canvas"
        return item
    }()
    private lazy var undoItem = barItem(symbol: "arrow.uturn.backward", label: "Undo") { $0.undo() }
    private lazy var redoItem = barItem(symbol: "arrow.uturn.forward", label: "Redo") { $0.redo() }
    private lazy var fitItem = barItem(title: "Fit", label: "Fit canvas in window") { $0.fit() }
    private lazy var actualItem = barItem(title: "100%", label: "Actual pixels") { $0.zoom(to: 1) }
    private lazy var zoomInItem = barItem(symbol: "plus.magnifyingglass", label: "Zoom in") { $0.zoomKeyboard(by: 1) }
    private lazy var zoomOutItem = barItem(symbol: "minus.magnifyingglass", label: "Zoom out") { $0.zoomKeyboard(by: -1) }
    private let rail = ToolRailView()
    private let canvasHost = UIView()
    private let newCanvas = NewCanvasView()
    private var fingerPaints = UserDefaults.standard.object(forKey: "fingerPaints") as? Bool ?? true

    private enum Picking { case project, images }
    private var picking: Picking?

    // MARK: Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.controllers.add(self)
        view.backgroundColor = UIColor(white: 0.14, alpha: 1)

        // The Mac's toolbar, group for group: New Canvas; the tabs, with no background of their own; and at the end
        // Fit, 100%, and zooming in and out, each group sharing a glass background. Undo and Redo lead the trailing
        // groups, for a window that may have no keyboard or menu bar in reach.
        navigationItem.leadingItemGroups = [UIBarButtonItemGroup(barButtonItems: [newTabItem], representativeItem: nil)]
        navigationItem.titleView = tabStrip
        navigationItem.trailingItemGroups = [[undoItem, redoItem], [fitItem], [actualItem], [zoomInItem, zoomOutItem]]
            .map { UIBarButtonItemGroup(barButtonItems: $0, representativeItem: nil) }

        tabStrip.onSelect = { [weak self] in self?.select($0) }
        tabStrip.onClose = { [weak self] in self?.close($0) }
        tabStrip.menu = { [weak self] in self?.tabMenu($0) }

        rail.presenter = self
        rail.fingerPaints = fingerPaints
        rail.onFingerPaintsChange = { [weak self] in self?.setFingerPaints($0) }

        newCanvas.onCreate = { [weak self] in self?.createCanvas(width: $0, height: $1) }
        newCanvas.onOpen = { [weak self] in self?.openProject(nil) }
        newCanvas.onImport = { [weak self] in self?.importImages(nil) }
        newCanvas.onOpenRecent = { [weak self] in self?.open([$0]) }

        let railLine = Self.separator(vertical: true)
        for subview in [rail, railLine, canvasHost, newCanvas] as [UIView] {
            view.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        // Under the bar, which keeps clear of the window controls iPadOS puts at the window's leading top corner.
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // The tools and the canvas side by side.
            rail.topAnchor.constraint(equalTo: safe.topAnchor), rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            railLine.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            railLine.topAnchor.constraint(equalTo: rail.topAnchor), railLine.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            canvasHost.leadingAnchor.constraint(equalTo: railLine.trailingAnchor),
            canvasHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasHost.topAnchor.constraint(equalTo: rail.topAnchor), canvasHost.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            newCanvas.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor), newCanvas.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
            newCanvas.topAnchor.constraint(equalTo: canvasHost.topAnchor), newCanvas.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
        ])
        if tabs.isEmpty { addTab() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }
    /// Undo and Redo in the menu bar, on the keyboard and in the system's gestures go to the tab in front.
    override var undoManager: UndoManager? { activeTab?.undoManager }

    /// Follows the tab in front: UIKit calls this again whenever anything it read from that tab's editor changes.
    override func updateProperties() {
        super.updateProperties()
        guard let tab = activeTab else { return }
        let session = tab.session
        tabStrip.show(tabs.map { .init(id: $0.id, title: $0.title, modified: $0.document != nil && $0.session.isModified) },
                      active: activeID)
        undoItem.isEnabled = session.canUndo
        redoItem.isEnabled = session.canRedo
        let hasDocument = session.document != nil
        for item in [fitItem, actualItem, zoomInItem, zoomOutItem] { item.isEnabled = hasDocument }
        newCanvas.isHidden = !tab.isEmpty
        view.window?.windowScene?.title = tab.title
        rail.session = session
        // What the editor asks of whoever shows it: a Photoshop file's conversion report, a RAW file's development,
        // and the errors it runs into. Shown once the update is over.
        if session.showsConversionSheet || session.showsRawDevelop || session.importError != nil
            || session.brushError != nil || session.cropError != nil {
            DispatchQueue.main.async { [weak self] in self?.presentEditorRequests(for: tab) }
        }
    }

    private func presentEditorRequests(for tab: EditorTab) {
        guard tab.id == activeID, presentedViewController == nil else { return }
        let session = tab.session
        if session.showsConversionSheet {
            presentSheet(PSDConversionController(session: session))
        } else if session.showsRawDevelop, let develop = session.rawDevelop {
            presentSheet(RawDevelopController(session: session, url: develop.url, settings: develop.settings))
        } else if let message = session.importError {
            session.importError = nil
            showMessage("Import couldn’t finish", message)
        } else if let message = session.brushError {
            session.brushError = nil
            showMessage("Couldn’t paint", message)
        } else if let message = session.cropError {
            session.cropError = nil
            showMessage("Couldn’t crop", message)
        }
    }

    // MARK: Tabs

    @discardableResult private func addTab() -> EditorTab {
        let tab = EditorTab()
        tabs.append(tab)
        select(tab.id)
        return tab
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeID = id
        canvasHost.subviews.forEach { $0.removeFromSuperview() }
        let canvas = tab.canvas
        canvas.fingerPaints = fingerPaints
        canvas.pencilSeen = { [weak self] in self?.setFingerPaints(false) }
        canvasHost.addSubview(canvas)
        canvas.frame = canvasHost.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        newCanvas.showRecent(PadRecentProjects.shared.urls)
        setNeedsUpdateProperties()
        becomeFirstResponder()
    }

    /// Saves and closes the tab's project. The last tab is replaced by an empty one, as on the Mac.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.session.commitTransform()
        Task { await tab.close() }
        if tabs.isEmpty { addTab() }
        else if activeID == id { select(tabs[min(index, tabs.count - 1)].id) }
        else { setNeedsUpdateProperties() }
    }

    private func tabMenu(_ id: UUID) -> UIMenu? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let fileActions: [UIMenuElement] = tab.document == nil ? [] : [
            UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.select(id); self?.renameProject(nil) },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.select(id); self?.duplicateProject(nil) },
            UIAction(title: "Export PNG…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.select(id); self?.exportPNG(nil) },
        ]
        let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.close(id) }
        return UIMenu(children: [UIMenu(options: .displayInline, children: fileActions), close])
    }

    private func setFingerPaints(_ paints: Bool) {
        fingerPaints = paints
        UserDefaults.standard.set(paints, forKey: "fingerPaints")
        rail.fingerPaints = paints
        activeTab?.canvas.fingerPaints = paints
    }

    // MARK: Opening

    /// Opens projects in tabs of their own (bringing forward one that's already open) and brings images into the
    /// project in front, as a drop on the Mac's window does.
    func open(_ urls: [URL]) {
        let projects = urls.filter { Self.isProject($0) }
        let images = urls.filter { !Self.isProject($0) }
        for url in projects { open(project: url) }
        if !images.isEmpty { bringIn(images) }
    }

    private func open(project url: URL) {
        for controller in Self.controllers.allObjects {
            guard let tab = controller.tabs.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) else { continue }
            controller.select(tab.id)
            if controller !== self, let scene = controller.view.window?.windowScene {
                UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: scene.session))
            }
            return
        }
        // An empty tab in front takes the project; otherwise it gets a tab of its own.
        let tab = activeTab.flatMap { $0.isEmpty ? $0 : nil } ?? addTab()
        let opening = tab.open(url)
        setNeedsUpdateProperties()
        Task {
            do {
                try await opening.value
                PadRecentProjects.shared.note(url)
            } catch {
                // The tab opened for it goes again, unless it's the window's last.
                if tab.isEmpty, tabs.count > 1 { close(tab.id) }
                showError("Couldn’t open “\(url.deletingPathExtension().lastPathComponent)”", error)
            }
            setNeedsUpdateProperties()
        }
    }

    /// Images into the project in front; into an empty tab, the first one sets the canvas and the project gets a file.
    private func bringIn(_ images: [URL]) {
        guard let tab = activeTab ?? tabs.first else { return }
        Task {
            await tab.session.importImages(images)
            do { try await tab.createDocument(named: images.first?.deletingPathExtension().lastPathComponent ?? "Untitled") }
            catch { showError("Couldn’t save the new project", error) }
            setNeedsUpdateProperties()
        }
    }

    private func createCanvas(width: Int, height: Int) {
        guard let tab = activeTab else { return }
        tab.session.createNewProject(width: width, height: height)
        Task {
            do { try await tab.createDocument(named: "Untitled") }
            catch { showError("Couldn’t save the new project", error) }
            setNeedsUpdateProperties()
        }
    }

    private static func isProject(_ url: URL) -> Bool {
        // A project is a package, a folder, so its type is looked up among packages rather than files.
        UTType(filenameExtension: url.pathExtension, conformingTo: .package)?.conforms(to: .compositorProject) == true
    }

    private func pick(_ kind: Picking) {
        picking = kind
        // Images are copied in, as the importer reads them once; projects are opened where they are.
        let picker = kind == .project
            ? UIDocumentPickerViewController(forOpeningContentTypes: [.compositorProject], asCopy: false)
            : UIDocumentPickerViewController(forOpeningContentTypes: UTType.importableImages.filter { $0 != .svg }, asCopy: true)
        picker.allowsMultipleSelection = kind == .images
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        switch picking {
        case .project: urls.first.map { open(project: $0) }
        case .images: bringIn(urls)
        case nil: break
        }
        picking = nil
    }

    // MARK: Commands (the menu bar, the keyboard and the buttons)

    @objc func newCanvasTab(_ sender: Any?) {
        if let empty = tabs.first(where: \.isEmpty) { select(empty.id) } else { addTab() }
    }
    @objc func openProject(_ sender: Any?) { pick(.project) }
    @objc func importImages(_ sender: Any?) { pick(.images) }
    @objc func openRecentProject(_ sender: UICommand) {
        if let reference = sender.propertyList as? Data, let url = PadRecentProjects.resolve(reference) { open([url]) }
    }

    /// Saves now, though the project saves itself as it changes; ⌘S is a habit worth keeping.
    @objc func saveProject(_ sender: Any?) {
        guard let tab = activeTab, let document = tab.document else { return }
        tab.session.commitTransform()
        Task {
            if !(await document.save(to: document.fileURL, for: .forOverwriting)) {
                showMessage("Couldn’t save the project", "It will be saved again when it next changes.")
            }
        }
    }

    @objc func duplicateProject(_ sender: Any?) {
        guard let document = activeTab?.document else { return }
        Task {
            do { open(project: try await document.duplicate()) }
            catch { showError("Couldn’t duplicate the project", error) }
        }
    }

    @objc func renameProject(_ sender: Any?) {
        guard let tab = activeTab, let document = tab.document else { return }
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = tab.title
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != tab.title else { return }
            Task {
                do { try await document.rename(to: name) }
                catch { self?.showError("Couldn’t rename the project", error) }
                self?.setNeedsUpdateProperties()
            }
        })
        present(alert, animated: true)
    }

    /// The flattened image as PNG, to share, save to Photos or keep in Files.
    @objc func exportPNG(_ sender: Any?) {
        guard let tab = activeTab, tab.session.canStartProjectOperation, let snapshot = tab.session.projectSnapshot() else { return }
        let name = tab.title
        Task {
            do {
                let data = try await ImageExporter.shared.pngData(snapshot)
                let url = FileManager.default.temporaryDirectory.appending(path: name + ".png")
                try data.write(to: url, options: .atomic)
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = tabStrip
                share.popoverPresentationController?.sourceRect = tabStrip.bounds
                present(share, animated: true)
            } catch { showError("Couldn’t export the image", error) }
        }
    }

    @objc func closeTab(_ sender: Any?) { if let id = activeID { close(id) } }
    @objc func fitCanvas(_ sender: Any?) { activeTab?.session.fit() }
    @objc func actualPixels(_ sender: Any?) { activeTab?.session.zoom(to: 1) }
    @objc func zoomIn(_ sender: Any?) { activeTab?.session.zoomKeyboard(by: 1) }
    @objc func zoomOut(_ sender: Any?) { activeTab?.session.zoomKeyboard(by: -1) }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let hasFile = activeTab?.document != nil
        let hasDocument = activeTab?.session.document != nil
        switch action {
        case #selector(saveProject(_:)), #selector(duplicateProject(_:)), #selector(renameProject(_:)): return hasFile
        case #selector(exportPNG(_:)), #selector(fitCanvas(_:)), #selector(actualPixels(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)): return hasDocument
        case #selector(newCanvasTab(_:)), #selector(openProject(_:)), #selector(importImages(_:)),
             #selector(openRecentProject(_:)), #selector(closeTab(_:)): return true
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    /// The Mac's single-key tools and color keys, on a hardware keyboard.
    override var keyCommands: [UIKeyCommand]? {
        let tools: [(String, NavigationTool)] = [("v", .move), ("b", .brush), ("r", .blur), ("i", .eyedropper), ("h", .hand), ("z", .zoom)]
        return tools.map { key, tool in
            UIKeyCommand(title: tool.label, action: #selector(toolKey(_:)), input: key, propertyList: tool.rawValue)
        } + [
            UIKeyCommand(title: "Eraser", action: #selector(eraserKey(_:)), input: "e"),
            UIKeyCommand(title: "Swap Colors", action: #selector(swapColorsKey(_:)), input: "x"),
            UIKeyCommand(title: "Default Colors", action: #selector(defaultColorsKey(_:)), input: "d"),
            UIKeyCommand(title: "Smaller Brush", action: #selector(brushSizeKey(_:)), input: "[", propertyList: false),
            UIKeyCommand(title: "Larger Brush", action: #selector(brushSizeKey(_:)), input: "]", propertyList: true),
        ]
    }
    @objc private func toolKey(_ command: UIKeyCommand) {
        guard let raw = command.propertyList as? String, let tool = NavigationTool(rawValue: raw),
              let session = activeTab?.session, session.document != nil else { return }
        session.selectTool(tool)
        if tool == .brush { session.brushMode = .paint }
    }
    @objc private func eraserKey(_ command: UIKeyCommand) {
        guard let session = activeTab?.session, session.document != nil else { return }
        session.selectTool(.brush)
        session.brushMode = .erase
    }
    @objc private func swapColorsKey(_ command: UIKeyCommand) { activeTab?.session.swapPaletteColors() }
    @objc private func defaultColorsKey(_ command: UIKeyCommand) { activeTab?.session.resetPaletteColors() }
    @objc private func brushSizeKey(_ command: UIKeyCommand) {
        guard let session = activeTab?.session, session.tool.isBrushTool else { return }
        session.changeBrushSize(increase: command.propertyList as? Bool == true)
    }

    // MARK: Restoration and the app's life

    /// The window's projects and the one in front, to open again when iPadOS brings the window back.
    var restorationActivity: NSUserActivity {
        let activity = NSUserActivity(activityType: Self.restorationActivityType)
        let open = tabs.compactMap { tab in tab.url.flatMap { PadRecentProjects.reference(to: $0) }.map { (tab, $0) } }
        activity.addUserInfoEntries(from: [
            "tabs": open.map(\.1),
            "active": open.firstIndex { $0.0.id == activeID } ?? 0,
        ])
        return activity
    }

    func restore(from activity: NSUserActivity) {
        guard activity.activityType == Self.restorationActivityType,
              let references = activity.userInfo?["tabs"] as? [Data], !references.isEmpty else { return }
        // A project moved or deleted since is left out.
        let urls = references.map { PadRecentProjects.resolve($0) }
        urls.forEach { $0.map { open(project: $0) } }
        if let active = activity.userInfo?["active"] as? Int, urls.indices.contains(active), let url = urls[active],
           let tab = tabs.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
            select(tab.id)
        }
    }

    /// Before iPadOS may quit the app in the background, every changed project is saved.
    func saveAll() {
        for tab in tabs { tab.document?.autosave(completionHandler: nil) }
    }

    func closeAll() {
        for tab in tabs { Task { await tab.close() } }
    }

    // MARK: Helpers

    /// A toolbar item acting on the tab in front's editor.
    private func barItem(title: String? = nil, symbol: String? = nil, label: String,
                         action: @escaping (EditorSession) -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, primaryAction: UIAction { [weak self] _ in
            guard let session = self?.activeTab?.session else { return }
            action(session)
        })
        item.accessibilityLabel = label
        return item
    }

    private func presentSheet(_ controller: UIViewController) {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func showError(_ title: String, _ error: any Error) { showMessage(title, error.localizedDescription) }

    private func showMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (presentedViewController ?? self).present(alert, animated: true)
    }

    /// A one-point line between regions, as the Mac's dividers are.
    static func separator(vertical: Bool) -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(white: 1, alpha: 0.08)
        line.translatesAutoresizingMaskIntoConstraints = false
        (vertical ? line.widthAnchor : line.heightAnchor).constraint(equalToConstant: 1).isActive = true
        return line
    }
}
