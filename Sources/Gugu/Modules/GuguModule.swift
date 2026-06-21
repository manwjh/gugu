import Foundation
import GuguKernel

/// 实验模块的统一挂载点。咕咕的"额外能力"(blog、以及后续更多实验)都做成
/// `GuguModule`,经 `ModuleRegistry` 按 config 开关激活/停用,彼此隔离、可整体摘除。
///
/// 设计意图:每个模块只通过 `ModuleContext` 这道窄门与 app 打交道(拿 brain、发声、
/// 读当前 config),**不直接抓全局单例**,这样加/删一个模块都不牵动其它代码。
@MainActor
protocol GuguModule: AnyObject {
    /// 稳定的模块标识(日志/去重用)。
    static var id: String { get }
    /// 此模块在当前 config 下是否启用(读各自的开关)。
    func isEnabled(_ config: Config) -> Bool
    /// 启用:接上下文、起服务、登记触发。幂等由 Registry 保证(同一模块不会重复激活)。
    func activate(_ context: ModuleContext)
    /// 停用:停服务、放资源。
    func deactivate()
}

/// 模块与 app 之间唯一的接口面。模块只拿到它真正需要的东西,
/// 而不是整个 GuguApp——保持松耦合,便于将来把模块拆成独立 target。
@MainActor
final class ModuleContext {
    let brain: Brain
    /// 让咕咕说一句(走气泡/TTS)。模块对外的唯一"发声"通道。
    let announce: (String) -> Void
    /// 当前配置(Registry 在 config 热重载时更新)。
    fileprivate(set) var config: Config

    init(config: Config, brain: Brain, announce: @escaping (String) -> Void) {
        self.config = config
        self.brain = brain
        self.announce = announce
    }
}

/// 持有所有已注册模块,按 config 同步激活状态(幂等)。config 热重载后再 `sync` 一次即可。
@MainActor
final class ModuleRegistry {
    let context: ModuleContext
    private var modules: [GuguModule] = []
    private var activeIDs: Set<String> = []

    init(context: ModuleContext) {
        self.context = context
    }

    func register(_ module: GuguModule) {
        modules.append(module)
    }

    /// 按当前 config:该开的开、该关的关。重复调用安全。
    func sync(config: Config) {
        context.config = config
        for module in modules {
            let id = type(of: module).id
            let want = module.isEnabled(config)
            if want, !activeIDs.contains(id) {
                module.activate(context)
                activeIDs.insert(id)
                Log.info("module", "激活模块 \(id)")
            } else if !want, activeIDs.contains(id) {
                module.deactivate()
                activeIDs.remove(id)
                Log.info("module", "停用模块 \(id)")
            }
        }
    }

    /// 取某个具体模块(供菜单等触发其能力)。
    func module<T: GuguModule>(_ type: T.Type) -> T? {
        modules.compactMap { $0 as? T }.first
    }
}
