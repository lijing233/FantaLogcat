import SwiftUI

extension DeviceTransport {
    /// 短标签，用于设备菜单顶部芯片与设备选择列表。
    func localizedLabel(_ copy: (String, String) -> String) -> String {
        switch self {
        case .usb: copy("USB", "USB")
        case .wirelessTLS: copy("无线 · 安全", "Wireless · Secure")
        case .wirelessTCPIP: copy("无线 TCP/IP", "Wireless TCP/IP")
        case .emulator: copy("模拟器", "Emulator")
        case .unknown: copy("未知", "Unknown")
        }
    }

    /// 连接方式详情，用于设备菜单展开后的说明。
    func detailText(_ copy: (String, String) -> String) -> String {
        switch self {
        case .usb: copy("USB 数据线连接", "USB cable connection")
        case .wirelessTLS: copy("Android 11+ TLS 无线调试", "Android 11+ TLS wireless debugging")
        case .wirelessTCPIP: copy("传统 TCP/IP 调试（由 USB 转无线建立）", "Legacy TCP/IP debugging (established via USB to wireless)")
        case .emulator: copy("Android 模拟器", "Android emulator")
        case .unknown: copy("未知连接", "Unknown connection")
        }
    }

    var tintColor: Color {
        switch self {
        case .usb: .blue
        case .wirelessTLS: .green
        case .wirelessTCPIP: .orange
        case .emulator: .purple
        case .unknown: .secondary
        }
    }
}
