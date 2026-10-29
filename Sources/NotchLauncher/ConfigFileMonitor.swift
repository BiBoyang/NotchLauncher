import Cocoa
import Darwin

/// 监听配置目录而非具体 inode,兼容编辑器通过临时文件原子替换 apps.json。
/// 内部写回会更新内容基准;只有真实内容变化才向控制器发回调。
final class ConfigFileMonitor {
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var debounceItem: DispatchWorkItem?
    private var lastData: Data?
    private var localWriteObserver: NSObjectProtocol?

    func start() {
        guard source == nil else { return }
        AppConfig.ensureExists()
        lastData = try? Data(contentsOf: AppConfig.fileURL)

        localWriteObserver = NotificationCenter.default.addObserver(
            forName: .launcherConfigDidWrite,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.debounceItem?.cancel()
            self?.lastData = try? Data(contentsOf: AppConfig.fileURL)
        }

        fileDescriptor = open(AppConfig.directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            nlLog("配置监控:无法打开目录 \(AppConfig.directoryURL.path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { [fileDescriptor] in close(fileDescriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        debounceItem?.cancel()
        debounceItem = nil
        source?.cancel()
        source = nil
        fileDescriptor = -1
        if let localWriteObserver {
            NotificationCenter.default.removeObserver(localWriteObserver)
            self.localWriteObserver = nil
        }
    }

    deinit { stop() }

    private func scheduleCheck() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkForChange() }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func checkForChange() {
        // 原子替换中间可能出现短暂不存在;保留旧基准,等待下一次目录事件。
        guard let data = try? Data(contentsOf: AppConfig.fileURL), data != lastData else { return }
        lastData = data
        onChange?()
    }
}
