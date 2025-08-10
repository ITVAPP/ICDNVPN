import 'dart:math' as math;

/// 应用全局配置
class AppConfig {
  // ===== 应用基础信息 =====
  static const String appName = 'CFVPN';
  static const String currentVersion = '1.0.1'; // 当前版本号
  static const String officialWebsite = 'https://www.example.com'; // 官方网站
  static const String contactEmail = 'abc@abc.com'; // 联系邮箱
  
  // ===== 日志配置 =====
  static const bool enableLogFile = true; // 是否启用文件日志
  static const bool enableLogConsole = false; // 是否启用控制台日志（调试用）
  static const bool enableLogAutoFlush = true; // 是否启用自动刷新
  static const Duration logAutoFlushInterval = Duration(seconds: 30); // 自动刷新间隔
  static const int logMaxOpenFiles = 10; // 最大同时打开的日志文件数
  static const Duration logDateCheckInterval = Duration(minutes: 1); // 日期检查间隔
  
  // ===== V2Ray端口配置 =====
  static const int v2raySocksPort = 7898; // SOCKS5代理端口
  static const int v2rayHttpPort = 7899; // HTTP代理端口
  static const int v2rayApiPort = 10085; // V2Ray API端口
  static const int v2rayDefaultServerPort = 443; // 默认服务器端口
  
  // ===== V2Ray服务配置 =====
  static const Duration v2rayStartupWait = Duration(seconds: 3); // V2Ray启动后等待时间
  static const Duration v2rayCheckDelay = Duration(seconds: 2); // V2Ray状态检查延迟
  static const Duration portCheckTimeout = Duration(seconds: 1); // 端口检查超时时间
  static const int v2rayTerminateRetries = 6; // V2Ray进程终止重试次数
  static const Duration v2rayTerminateInterval = Duration(milliseconds: 500); // 终止重试间隔
  
  // ===== V2Ray服务器群组配置 =====
  // 服务器群组用于指定多个后端服务器域名，实现域前置的灵活切换
  // 注意：这里只配置serverName（SNI和Host头），不配置address
  // TCP连接始终使用Cloudflare CDN IP，通过Host头路由到不同后端
  // 
  // 工作原理：
  // 1. 客户端始终连接到Cloudflare CDN IP（如172.67.x.x）
  // 2. 通过设置不同的Host头，CDN会将流量转发到对应的后端服务器
  // 3. 这样可以在不改变CDN IP的情况下，切换多个后端服务器
  //
  // 示例配置：
  // static const List<Map<String, dynamic>> serverGroup = [
  //   {'serverName': 'server1.pages.dev'},   // 后端服务器1
  //   {'serverName': 'server2.pages.dev'},   // 后端服务器2
  // ];
  //
  // 留空则使用v2ray_config.json中的默认配置
  static const List<Map<String, dynamic>> serverGroup = [
    // 默认为空，使用JSON配置文件中的serverName
    // 如需配置多个后端服务器，请按上述示例添加
  ];
  
  // 获取随机服务器
  // 返回的Map中包含serverName字段，用于设置SNI和Host头
  // 注意：address和port字段将被忽略，始终使用CDN IP
  static Map<String, dynamic>? getRandomServer() {
    if (serverGroup.isEmpty) return null;
    final random = math.Random();
    return serverGroup[random.nextInt(serverGroup.length)];
  }
  
  // ===== Cloudflare配置 =====
  // Cloudflare官方IP段（2025年最新版本）
  static const List<String> cloudflareIpRanges = [
    '173.245.48.0/20',
    '103.21.244.0/22',
    '103.22.200.0/22',
    '103.31.4.0/22',
    '141.101.64.0/18',
    '108.162.192.0/18',
    '190.93.240.0/20',
    '188.114.96.0/20',
    '197.234.240.0/22',
    '198.41.128.0/17',
    '162.158.0.0/15',
    '104.16.0.0/12',
    '172.64.0.0/17',
    '172.64.128.0/18',
    '172.64.192.0/19',
    '172.64.224.0/22',
    '172.64.229.0/24',
    '172.64.230.0/23',
    '172.64.232.0/21',
    '172.64.240.0/21',
    '172.64.248.0/21',
    '172.65.0.0/16',
    '172.66.0.0/16',
    '172.67.0.0/16',
    '131.0.72.0/22',
  ];
  
  // ===== 网络测试配置 =====
  // 测试参数配置
  static const int defaultSampleCount = 500; // 默认采样IP数量
  static const int defaultTestNodeCount = 5; // 默认最终选择节点数
  static const int defaultMaxLatency = 300; // 默认最大可接受延迟(ms)
  
  // TCPing配置
  static const Duration tcpTimeout = Duration(seconds: 1); // TCP连接超时时间
  static const int tcpPingTimes = 3; // TCPing测试次数
  static const int minValidTcpLatency = 30; // TCPing最小有效延迟(ms)，避免假连接
  static const Duration tcpTestInterval = Duration(milliseconds: 50); // TCPing测试间隔
  
  // HTTPing配置
  static const int httpingTimeout = 2000; // HTTPing超时时间(ms)
  static const int httpingTestIpCount = 200; // TCPing失败后HTTPing重试的IP数量
  
  // 批处理配置
  static const int minBatchSize = 10; // 最小批处理大小
  static const int maxBatchSize = 20; // 最大批处理大小
  
  // ===== 服务器管理配置 =====
  static const int autoSelectLatencyThreshold = 200; // 自动选择服务器的延迟阈值(ms)
  static const int autoSelectRangeThreshold = 30; // 自动选择服务器的延迟范围(ms)
  static const int goodNodeLatencyThreshold = 300; // 优质节点延迟阈值(ms)
  static const double goodNodeLossRateThreshold = 0.1; // 优质节点丢包率阈值(10%)
  static const int earlyStopGoodNodeCount = 10; // 提前结束测试的优质节点数量
  
  // ===== 性能配置 =====
  static const Duration trafficStatsInterval = Duration(seconds: 10); // 流量统计更新间隔
  
  // ===== 缓存配置 =====
  static const Duration userInfoCacheExpiry = Duration(hours: 72); // 用户信息缓存过期时间
  static const Duration versionCheckCacheExpiry = Duration(hours: 1); // 版本检查结果缓存时间
  
  // ===== 窗口配置（桌面平台） =====
  static const double defaultWindowWidth = 400; // 默认窗口宽度
  static const double defaultWindowHeight = 720; // 默认窗口高度
  static const double minWindowWidth = 380; // 最小窗口宽度
  static const double minWindowHeight = 650; // 最小窗口高度
  static const double customTitleBarHeight = 40; // 自定义标题栏高度
  
  // ===== 广告配置 =====
  static const String adConfigUrl = 'assets/js/ad.json'; // 本地测试
  // static const String adConfigUrl = 'https://example.com/api/ad.json'; // 线上地址
  
  // 广告刷新间隔
  static const Duration adCacheExpiry = Duration(hours: 1);
  
  // 文字广告轮播间隔
  static const Duration textAdSwitchInterval = Duration(seconds: 5);
  
  // 图片广告显示控制
  static const int maxImageAdShowPerDay = 3; // 每天最多显示次数
  static const Duration imageAdCooldown = Duration(hours: 2); // 关闭后冷却时间
  
  // 图片广告显示时长（统一10秒）
  static const int imageAdDisplaySeconds = 10;
  
  // ===== 版本更新配置 =====
  // 版本检查API（本地测试用assets，生产用https）
  static const String versionApiUrl = 'assets/js/version.json';
  // static const String versionApiUrl = 'https://your-api.com/version.json';
  
  // 备用版本API（可选）
  static const String? versionApiBackupUrl = null;
  // static const String? versionApiBackupUrl = 'https://backup-api.com/version.json';
  
  // 检查间隔
  static const Duration updateCheckInterval = Duration(hours: 24);
  static const Duration updatePromptInterval = Duration(hours: 24);
  
  // ===== 应用商店配置 =====
  // iOS App Store ID（用于跳转到App Store）
  static const String? iosAppStoreId = null; // 例如: '1234567890'
  // static const String? iosAppStoreId = '1234567890';
  
  // macOS App Store ID（如果有Mac版本）
  static const String? macAppStoreId = null;
  
  // 各平台下载地址模板（版本更新时使用）
  // 可以使用 {version} 占位符替换版本号
  static const String androidDownloadUrlTemplate = 'https://example.com/download/android/cfvpn_{version}.apk';
  static const String windowsDownloadUrlTemplate = 'https://example.com/download/windows/cfvpn_{version}_setup.exe';
  static const String macosDownloadUrlTemplate = 'https://example.com/download/macos/cfvpn_{version}.dmg';
  static const String linuxDownloadUrlTemplate = 'https://example.com/download/linux/cfvpn_{version}.AppImage';
  
  // 获取iOS App Store链接
  static String? getIosAppStoreUrl() {
    if (iosAppStoreId == null) return null;
    return 'https://apps.apple.com/app/id$iosAppStoreId';
  }
  
  // 获取macOS App Store链接
  static String? getMacAppStoreUrl() {
    if (macAppStoreId == null) return null;
    return 'https://apps.apple.com/app/id$macAppStoreId';
  }
  
  // ===== 统计配置 =====
  // 统计API地址（留空表示不统计）
  static const String analyticsApiUrl = '';
  // static const String analyticsApiUrl = 'https://your-analytics.com/api/track';
  
  // 统计间隔
  static const Duration analyticsInterval = Duration(hours: 24);
  
  // ===== 隐私政策配置 =====
  // 隐私政策JSON文件地址（本地测试用assets，生产用https）
  static const String privacyPolicyUrl = 'assets/js/privacy_policy.json';
  // static const String privacyPolicyUrl = 'https://your-api.com/privacy_policy.json';
}
