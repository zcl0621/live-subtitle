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
        // ① 麦克风:异步弹权限框,不关心结果。
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // ② 屏幕录制(系统音频采集依赖此授权)。
        // 仅在尚未授权时触发系统授权引导。CGRequestScreenCaptureAccess 是同步阻塞的
        // C API,放到后台队列执行以免阻塞主线程弹窗时机;它只触发 TCC,无需回主线程更新 UI。
        if CGPreflightScreenCaptureAccess() == false {
            DispatchQueue.global().async {
                _ = CGRequestScreenCaptureAccess()
            }
        }
    }
}
