# StarBridge 星台 · 变更记录

## v0.9.10 (2026-09-09)
- **商业沙盘入口**：标题栏橙色 🎮 按钮 → SFSafari 内嵌打开 推演工作台(明鉴 flowernet 100轮, /sb/wargame, 服务端代理 8812)
- server.js: /wargame* 代理 127.0.0.1:8812(默认=bench 推演工作台; 支持 tree/layers/board/playback)
- 协作: 明鉴发起, 星桥知悉; 手机在路上可测

## v0.9.9.1 (2026-09-09 · tag v0.9.9.1)
- **修复**：会话历史键角色感知——切换角色加载该角色独立会话（不再串上一个会话）
- 版本管理起点：git 入仓（排除 DerivedData/.token/uploads/旧 .bak）

## v0.9.9 (2026-09-09)
- **角色直聊**：server /api/chat 支持 target=20 主角色 → bus-envelope 直达其会话（central-inbox [direct] 注入，实测明鉴/司库）
- **DeepSeek 账户页**：标题栏钱包入口 → 官方余额(/user/balance, key 服务端) + 到账构成 + 刷新 + ⚡快速充值（SFSafariViewController 内嵌不退出）
- 余额未配 key 时优雅降级（未配置态）

## v0.9.8.2 (2026-09-09 · 基线入仓)
- 抽屉「角色管理」：20 主角色白名单 + 状态点（非 session 编号显示）
- 构建配置：team XS7SMKFS42 / iPhone 16 Pro 安装验证
