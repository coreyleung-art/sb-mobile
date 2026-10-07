import Foundation
/// 星台桥配置：服务器公网优先（永续通讯，不依赖 Tailscale VPN）；ts.net 作降级备用通道
struct BridgeConfig {
    static let baseURL = "https://xingqiao.meetfunbp.com/sb"
    static let baseURLFallback = "https://coreymac-mini.taild3fd86.ts.net/sb"
    static let token = "c4464dc37525935aece1892c2cfebf6c"
    static let pollInterval: TimeInterval = 1.5
}
