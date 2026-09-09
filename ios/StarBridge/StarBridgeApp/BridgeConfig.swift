import Foundation
/// 星台桥配置：Funnel 公网（任何网络可达——局域网/Tailscale 均不需要）
struct BridgeConfig {
    static let baseURL = "https://coreymac-mini.taild3fd86.ts.net/sb"
    static let token = "c4464dc37525935aece1892c2cfebf6c"
    static let pollInterval: TimeInterval = 1.5
}
