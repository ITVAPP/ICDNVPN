// lib/config/app_config.dart

/// 应用全局配置
class AppConfig {
  // 广告配置
  static const String adConfigUrl = 'assets/js/ad.json'; // 本地测试
  // static const String adConfigUrl = 'https://example.com/api/ad.json'; // 线上地址
  
  // 广告刷新间隔
  static const Duration adCacheExpiry = Duration(hours: 1);
  
  // 文字广告轮播间隔
  static const Duration textAdSwitchInterval = Duration(seconds: 5);
  
  // 图片广告显示控制
  static const int maxImageAdShowPerDay = 3; // 每天最多显示次数
  static const Duration imageAdCooldown = Duration(hours: 2); // 关闭后冷却时间
}
