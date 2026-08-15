import Foundation
import AVFoundation
import CoreGraphics

/// 权限申请:麦克风 + 屏幕录制(后者是 ScreenCaptureKit 采系统声音的前提)。
///
/// **必须在「开始字幕」时调用,不能在 app 启动阶段调用。** 实测(macOS 27):
/// 启动阶段同时拉起这两个 TCC 授权流程,会导致 SwiftUI `MenuBarExtra` 的状态栏项
/// 根本建不出来——菜单栏上没有图标、也没有任何报错,app 却在正常运行。
/// 单独请求任一项都正常;两项同时请求则必现;把请求延后 2 秒也无效。
@MainActor
enum PermissionsManager {
    /// 在真正要用权限时调用(点「开始字幕」)。非阻塞:两项各自异步触发系统授权框,忽略结果。
    static func requestAll() {
        // ① 麦克风:已授权就别再调 —— requestAccess 在已授权时本就不弹框,但显式跳过
        // 能让日志把"到底谁在弹"分辨出来(排"一次启动弹很多次"时唯一能用的线索)。
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        lslog("requestAll:麦克风当前状态=\(mic.rawValue)(0=未决 1=受限 2=拒绝 3=已授权)")
        if mic == .notDetermined {
            lslog("requestAll:→ 弹麦克风授权框")
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                lslog("requestAll:麦克风授权结果=\(ok)")
            }
        }

        // ② 屏幕录制(系统音频采集依赖此授权)。
        lslog("requestAll:屏幕录制已授权=\(CGPreflightScreenCaptureAccess())")
        // 仅在尚未授权时触发系统授权引导。CGRequestScreenCaptureAccess 是同步阻塞的
        // C API,放到后台队列执行以免阻塞主线程弹窗时机;它只触发 TCC,无需回主线程更新 UI。
        if CGPreflightScreenCaptureAccess() == false {
            DispatchQueue.global().async {
                _ = CGRequestScreenCaptureAccess()
            }
        }
    }

    /// **只**要麦克风,不碰屏幕录制 —— 设置页录声纹用。
    /// 单独一条而不是复用 `requestAll()`:那条会连带拉起屏幕录制授权,
    /// 而录声纹跟屏幕录制毫无关系,凭空多弹一个吓人的授权框;
    /// 且上面那条注释记的「两个 TCC 流程同时拉起」的坑正是要躲开的。
    ///
    /// 返回是否已授权。已被拒绝时返回 false —— 系统不会再弹框,调用方必须给出
    /// 「去系统设置里勾」的可操作提示,而不是干等一个永远不来的授权。
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false      // .denied / .restricted,以及将来新增的状态
        }
    }
}
