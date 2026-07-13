import Foundation
import AVFoundation
import CoreGraphics

/// 前置权限申请:app 启动时一次性请求麦克风 + 屏幕录制授权。
/// 屏幕录制授权是系统声音采集(ScreenCaptureKit)所需的前提。
@MainActor
enum PermissionsManager {
    /// 供 App 启动时调用。非阻塞:两项权限各自异步触发系统授权框,忽略结果。
    static func requestAllOnLaunch() {
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
