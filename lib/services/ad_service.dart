import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_config.dart';

// ==================== 广告数据模型 ====================

/// 广告内容模型
class AdContent {
  final String? text;          // 文字广告内容
  final String? imageUrl;      // 图片广告URL
  final String? url;           // 点击跳转URL
  final int? displayDuration;  // 图片广告显示时长（秒）

  AdContent({
    this.text,
    this.imageUrl,
    this.url,
    this.displayDuration,
  });

  factory AdContent.fromJson(Map<String, dynamic> json) {
    return AdContent(
      text: json['text'],
      imageUrl: json['imageUrl'],
      url: json['url'],
      displayDuration: json['displayDuration'],
    );
  }
}

/// 广告模型
class AdModel {
  final String id;
  final String type;         // 'text' 或 'image'
  final List<String> pages;  // 显示页面列表
  final AdContent content;
  final int priority;
  final DateTime validUntil;

  AdModel({
    required this.id,
    required this.type,
    required this.pages,
    required this.content,
    required this.priority,
    required this.validUntil,
  });

  factory AdModel.fromJson(Map<String, dynamic> json) {
    return AdModel(
      id: json['id'],
      type: json['type'],
      pages: List<String>.from(json['pages']),
      content: AdContent.fromJson(json['content']),
      priority: json['priority'],
      validUntil: DateTime.parse(json['validUntil']),
    );
  }

  /// 检查广告是否有效
  bool get isValid => DateTime.now().isBefore(validUntil);

  /// 检查广告是否应该在指定页面显示
  bool shouldShowOnPage(String page) => pages.contains(page);
}

/// 广告配置模型
class AdConfig {
  final String version;
  final bool enabled;
  final List<AdModel> ads;

  AdConfig({
    required this.version,
    required this.enabled,
    required this.ads,
  });

  factory AdConfig.fromJson(Map<String, dynamic> json) {
    return AdConfig(
      version: json['version'],
      enabled: json['enabled'],
      ads: (json['ads'] as List)
          .map((ad) => AdModel.fromJson(ad))
          .where((ad) => ad.isValid) // 过滤过期广告
          .toList(),
    );
  }
}

// ==================== 广告服务 ====================

/// 广告服务 - 管理广告的获取、缓存和显示逻辑
class AdService extends ChangeNotifier {
  List<AdModel> _ads = [];
  DateTime? _lastLoadTime;
  final Map<String, List<DateTime>> _imageAdShowHistory = {};
  final Random _random = Random();

  /// 获取所有广告
  List<AdModel> get ads => _ads;

  /// 初始化广告服务
  Future<void> initialize() async {
    await loadAds();
  }

  /// 加载广告配置
  Future<void> loadAds() async {
    try {
      // 检查缓存是否过期
      if (_lastLoadTime != null &&
          DateTime.now().difference(_lastLoadTime!) < AppConfig.adCacheExpiry) {
        return; // 使用缓存
      }

      String jsonString;

      if (AppConfig.adConfigUrl.startsWith('assets/')) {
        // 加载本地文件
        try {
          jsonString = await rootBundle.loadString(AppConfig.adConfigUrl);
        } catch (e) {
          debugPrint('加载本地广告配置失败: $e');
          return;
        }
      } else {
        // 加载网络文件
        try {
          final response = await http.get(
            Uri.parse(AppConfig.adConfigUrl),
            headers: {'Accept': 'application/json'},
          ).timeout(const Duration(seconds: 5));

          if (response.statusCode != 200) {
            debugPrint('广告配置请求失败: ${response.statusCode}');
            return;
          }

          jsonString = response.body;
        } catch (e) {
          debugPrint('加载网络广告配置失败: $e');
          return;
        }
      }

      // 解析JSON
      try {
        final Map<String, dynamic> jsonData = json.decode(jsonString);
        final adConfig = AdConfig.fromJson(jsonData);

        if (adConfig.enabled) {
          _ads = adConfig.ads;
          _lastLoadTime = DateTime.now();
          notifyListeners();
        } else {
          _ads = [];
          notifyListeners();
        }
      } catch (e) {
        debugPrint('解析广告配置失败: $e');
        _ads = [];
      }
    } catch (e) {
      debugPrint('加载广告时发生未知错误: $e');
      _ads = [];
    }
  }

  /// 获取指定页面的广告
  List<AdModel> getAdsForPage(String page, {String? type, int? limit}) {
    var filteredAds = _ads.where((ad) {
      if (!ad.shouldShowOnPage(page)) return false;
      if (type != null && ad.type != type) return false;
      return true;
    }).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    
    if (limit != null && filteredAds.length > limit) {
      // 随机选择指定数量的广告
      filteredAds.shuffle(_random);
      filteredAds = filteredAds.take(limit).toList();
    }
    
    return filteredAds;
  }

  /// 获取指定页面的文字广告
  List<AdModel> getTextAdsForPage(String page, {int? limit}) {
    return getAdsForPage(page, type: 'text', limit: limit);
  }

  /// 检查图片广告是否应该显示
  bool shouldShowImageAd(String adId) {
    // 检查今日显示次数
    final history = _imageAdShowHistory[adId] ?? [];
    final today = DateTime.now();
    final todayCount = history.where((time) =>
        time.year == today.year &&
        time.month == today.month &&
        time.day == today.day).length;

    return todayCount < AppConfig.maxImageAdShowPerDay;
  }

  /// 记录图片广告显示
  void recordImageAdShow(String adId) {
    _imageAdShowHistory[adId] ??= [];
    _imageAdShowHistory[adId]!.add(DateTime.now());
    // 清理过期记录（保留最近7天）
    final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
    _imageAdShowHistory[adId] = _imageAdShowHistory[adId]!
        .where((time) => time.isAfter(sevenDaysAgo))
        .toList();
  }

  /// 记录图片广告关闭
  Future<void> recordImageAdClose(String adId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ad_close_time_$adId', DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('记录广告关闭时间失败: $e');
    }
  }

  /// 检查冷却时间
  Future<bool> _checkCooldown(String adId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastCloseTimeStr = prefs.getString('ad_close_time_$adId');
      if (lastCloseTimeStr != null) {
        final lastCloseTime = DateTime.parse(lastCloseTimeStr);
        final timeSinceClose = DateTime.now().difference(lastCloseTime);
        return timeSinceClose >= AppConfig.imageAdCooldown;
      }
    } catch (e) {
      debugPrint('检查冷却时间失败: $e');
    }
    return true; // 如果出错，允许显示
  }

  /// 获取指定页面的图片广告（随机选择一个）- 异步版本（完整版，检查冷却时间）
  Future<AdModel?> getImageAdForPageAsync(String page) async {
    final imageAds = getAdsForPage(page, type: 'image');
    if (imageAds.isEmpty) return null;

    // 异步检查冷却时间和显示次数
    final List<AdModel> availableAds = [];
    for (final ad in imageAds) {
      if (shouldShowImageAd(ad.id) && await _checkCooldown(ad.id)) {
        availableAds.add(ad);
      }
    }
    
    if (availableAds.isEmpty) return null;

    // 随机选择一个
    return availableAds[_random.nextInt(availableAds.length)];
  }
}

// ==================== 文字广告轮播组件 ====================

/// 文字广告轮播组件 - 用于主页面
class TextAdCarousel extends StatefulWidget {
  final List<AdModel> ads;
  final double height;

  const TextAdCarousel({
    Key? key,
    required this.ads,
    this.height = 60,
  }) : super(key: key);

  @override
  State<TextAdCarousel> createState() => _TextAdCarouselState();
}

class _TextAdCarouselState extends State<TextAdCarousel>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  Timer? _timer;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    _animationController.forward();

    if (widget.ads.length > 1) {
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer = Timer.periodic(AppConfig.textAdSwitchInterval, (timer) {
      if (mounted) {
        setState(() {
          _currentIndex = (_currentIndex + 1) % widget.ads.length;
        });
        _animationController.forward(from: 0);
      }
    });
  }

  Future<void> _openUrl(String? url) async {
    if (url == null || url.isEmpty) return;

    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('打开广告链接失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.ads.isEmpty) return const SizedBox.shrink();

    final currentAd = widget.ads[_currentIndex];
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTap: () => _openUrl(currentAd.content.url),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10), // 添加与节点卡片相同的margin
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.primaryColor.withOpacity(isDark ? 0.2 : 0.1),
              theme.primaryColor.withOpacity(isDark ? 0.1 : 0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(20), // 与节点卡片相同的圆角
          border: Border.all(
            color: theme.primaryColor.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // 广告图标 - 与节点卡片的圆形国旗相同样式
            Container(
              width: 50, // 与主页节点卡片的国旗大小一致
              height: 50,
              decoration: BoxDecoration(
                color: theme.primaryColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withOpacity(0.8),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                  BoxShadow(
                    color: theme.primaryColor.withOpacity(0.4),
                    blurRadius: 8,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  'AD',
                  style: TextStyle(
                    fontSize: 50 * 0.35, // 与国旗组件的字号比例一致
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: Colors.black.withOpacity(0.5),
                        offset: const Offset(1, 1),
                        blurRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 15), // 与节点卡片相同的间距
            // 广告文字
            Expanded(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Text(
                  currentAd.content.text ?? '',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: theme.textTheme.bodyLarge?.color,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            // 如果有链接，显示箭头
            if (currentAd.content.url != null) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: theme.hintColor,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ==================== 文字广告卡片组件 ====================

/// 文字广告卡片组件 - 用于服务器列表页面
class TextAdCard extends StatelessWidget {
  final AdModel ad;

  const TextAdCard({
    Key? key,
    required this.ad,
  }) : super(key: key);

  Future<void> _openUrl(String? url) async {
    if (url == null || url.isEmpty) return;

    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('打开广告链接失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return MouseRegion(
      cursor: ad.content.url != null 
          ? SystemMouseCursors.click 
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: ad.content.url != null 
            ? () => _openUrl(ad.content.url) 
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.primaryColor.withOpacity(isDark ? 0.2 : 0.15),
                theme.primaryColor.withOpacity(isDark ? 0.1 : 0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(16), // 与节点卡片相同的圆角
            border: Border.all(
              color: theme.primaryColor.withOpacity(0.3),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: theme.brightness == Brightness.dark
                  ? Colors.black.withOpacity(0.2)
                  : Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
            child: Row(
              children: [
                // 广告图标容器 - 与节点卡片的国旗样式一致
                Container(
                  width: 56, // 与服务器列表页的国旗大小一致
                  height: 56,
                  decoration: BoxDecoration(
                    color: theme.primaryColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.8),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                      BoxShadow(
                        color: theme.primaryColor.withOpacity(0.4),
                        blurRadius: 8,
                        spreadRadius: -2,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      'AD',
                      style: TextStyle(
                        fontSize: 56 * 0.35, // 与国旗组件的字号比例一致
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Colors.black.withOpacity(0.5),
                            offset: const Offset(1, 1),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // 广告内容
                Expanded(
                  child: Text(
                    ad.content.text ?? '',
                    style: TextStyle(
                      fontSize: 14, // 与节点名称字号一致
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // 链接指示器
                if (ad.content.url != null) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.open_in_new,
                    size: 18,
                    color: theme.primaryColor.withOpacity(0.6),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 图片广告遮罩组件 ====================

/// 图片广告遮罩组件
class ImageAdOverlay extends StatefulWidget {
  final AdModel ad;
  final AdService adService;
  final VoidCallback onClose;

  const ImageAdOverlay({
    Key? key,
    required this.ad,
    required this.adService,
    required this.onClose,
  }) : super(key: key);

  @override
  State<ImageAdOverlay> createState() => _ImageAdOverlayState();
}

class _ImageAdOverlayState extends State<ImageAdOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  Timer? _countdownTimer;
  int _remainingSeconds = 0;
  bool _isImageLoaded = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));

    _animationController.forward();

    // 记录广告显示
    widget.adService.recordImageAdShow(widget.ad.id);

    // 设置倒计时
    _remainingSeconds = widget.ad.content.displayDuration ?? 5;
    _startCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _remainingSeconds--;
        });
        if (_remainingSeconds <= 0) {
          _closeAd();
        }
      }
    });
  }

  void _closeAd() {
    _countdownTimer?.cancel();
    widget.adService.recordImageAdClose(widget.ad.id);
    _animationController.reverse().then((_) {
      widget.onClose();
    });
  }

  Future<void> _openUrl() async {
    final url = widget.ad.content.url;
    if (url == null || url.isEmpty) return;

    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        _closeAd(); // 打开链接后关闭广告
      }
    } catch (e) {
      debugPrint('打开广告链接失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Stack(
        children: [
          // 透明背景，仅用于防止点击穿透
          GestureDetector(
            onTap: () {}, // 防止点击穿透
            child: Container(
              color: Colors.transparent,
            ),
          ),
          // 中心内容
          Center(
            child: Container(
              constraints: BoxConstraints(
                maxHeight: screenSize.height * 0.7,
                maxWidth: screenSize.width * 0.9,
              ),
              child: Stack(
                children: [
                  // 广告图片容器
                  GestureDetector(
                    onTap: widget.ad.content.url != null ? _openUrl : null,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: _buildImage(),
                      ),
                    ),
                  ),
                  // 顶部控制栏
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // 倒计时
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.timer_outlined,
                                color: Colors.white,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$_remainingSeconds秒后自动关闭',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 关闭按钮
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _closeAd,
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.6),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 点击提示（如果有链接）
                  if (widget.ad.content.url != null && _isImageLoaded)
                    Positioned(
                      bottom: 12,
                      left: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: theme.primaryColor.withOpacity(0.9),
                          borderRadius: BorderRadius.circular(25),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.touch_app,
                              color: Colors.white,
                              size: 18,
                            ),
                            SizedBox(width: 8),
                            Text(
                              '点击了解详情',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImage() {
    final imageUrl = widget.ad.content.imageUrl;
    if (imageUrl == null || imageUrl.isEmpty) {
      return Container(
        color: Colors.grey[300],
        child: const Center(
          child: Icon(Icons.image_not_supported, size: 48),
        ),
      );
    }

    // 判断是本地还是网络图片
    if (imageUrl.startsWith('assets/')) {
      return Image.asset(
        imageUrl,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: Colors.grey[300],
            child: const Center(
              child: Icon(Icons.broken_image, size: 48),
            ),
          );
        },
      );
    } else {
      return Image.network(
        imageUrl,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) {
            // 图片加载完成
            if (!_isImageLoaded) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _isImageLoaded = true;
                  });
                }
              });
            }
            return child;
          }
          // 加载中
          return Container(
            color: Colors.grey[200],
            child: Center(
              child: CircularProgressIndicator(
                value: loadingProgress.expectedTotalBytes != null
                    ? loadingProgress.cumulativeBytesLoaded /
                        loadingProgress.expectedTotalBytes!
                    : null,
              ),
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: Colors.grey[300],
            child: const Center(
              child: Icon(Icons.broken_image, size: 48),
            ),
          );
        },
      );
    }
  }
}