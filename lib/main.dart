import 'dart:io' show Platform, exit;
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'providers/app_provider.dart';
import 'pages/home_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'services/cloudflare_test_service.dart';
import 'utils/diagnostic_tool.dart';
import 'services/v2ray_service.dart';
import 'services/proxy_service.dart';
import 'services/ad_service.dart';
import 'services/version_service.dart';  // 新增：引入版本服务
import 'l10n/app_localizations.dart';
import 'app_config.dart';

// 自定义滚动行为类 - 用于控制滚动条在桌面平台的显示
class CustomScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
  };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    // 根据平台判断
    switch (getPlatform(context)) {
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        // 桌面平台始终显示滚动条
        return Scrollbar(
          controller: details.controller,
          thumbVisibility: true, // 始终显示滚动条
          child: child,
        );
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        // 移动平台保持默认行为
        return child;
    }
  }
  
  TargetPlatform getPlatform(BuildContext context) {
    return Theme.of(context).platform;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 设置系统UI样式
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );
  
  // 初始化窗口管理器（仅桌面平台）- 使用AppConfig
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();
    
    // 等待窗口准备就绪
    await windowManager.waitUntilReadyToShow();
    
    // 设置窗口选项 - 使用AppConfig
    WindowOptions windowOptions = WindowOptions(
      size: Size(AppConfig.defaultWindowWidth, AppConfig.defaultWindowHeight),
      minimumSize: Size(AppConfig.minWindowWidth, AppConfig.minWindowHeight),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden, // 隐藏标题栏
      windowButtonVisibility: false, // 隐藏窗口按钮
    );
    
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      // 设置阻止关闭，以便自定义关闭行为
      await windowManager.setPreventClose(true);
    });
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        ChangeNotifierProvider(create: (_) => ServerProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => AdService()..initialize()),
        ChangeNotifierProvider(create: (_) => DownloadProvider()), // 新增：下载服务
      ],
      child: Consumer2<ThemeProvider, LocaleProvider>(
        builder: (context, themeProvider, localeProvider, child) {
          return MaterialApp(
            title: AppConfig.appName,
            debugShowCheckedModeBanner: false,
            scrollBehavior: CustomScrollBehavior(), // 使用自定义滚动行为
            themeMode: themeProvider.themeMode,
            theme: _buildLightTheme(),
            darkTheme: _buildDarkTheme(),
            locale: localeProvider.locale,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            // 添加语言解析回调，确保默认使用中文
            localeResolutionCallback: (locale, supportedLocales) {
              // 如果用户没有设置语言偏好，返回中文
              if (localeProvider.locale == null) {
                return const Locale('zh', 'CN');
              }
              
              // 检查是否支持用户的语言
              for (final supportedLocale in supportedLocales) {
                if (supportedLocale.languageCode == locale?.languageCode) {
                  return supportedLocale;
                }
              }
              
              // 如果不支持，返回中文
              return const Locale('zh', 'CN');
            },
            home: const MainScreen(),
          );
        },
      ),
    );
  }

  // 浅色主题
  ThemeData _buildLightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.light,
      ),
      // 卡片主题
      cardTheme: CardTheme(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      // 应用栏主题
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
      ),
      // 输入框主题
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey.shade100,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.blue, width: 2),
        ),
      ),
      // 按钮主题
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      // 芯片主题
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      // 脚手架背景色
      scaffoldBackgroundColor: const Color(0xFFF5F5F5),
    );
  }

  // 深色主题
  ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.dark,
      ),
      // 卡片主题
      cardTheme: CardTheme(
        elevation: 0,
        color: const Color(0xFF1E1E1E),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      // 应用栏主题
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
      ),
      // 输入框主题
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey.shade800,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.blue, width: 2),
        ),
      ),
      // 按钮主题
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      // 脚手架背景色
      scaffoldBackgroundColor: const Color(0xFF121212),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin, WindowListener {
  int _currentIndex = 0;
  late AnimationController _fabAnimController;
  late Animation<double> _fabAnimation;
  
  final List<Widget> _pages = [
    const HomePage(),
    const ServersPage(),
    const SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    
    // 添加窗口监听器
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      windowManager.addListener(this);
    }
    
    _fabAnimController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fabAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(
      parent: _fabAnimController,
      curve: Curves.easeInOut,
    ));
    _fabAnimController.forward();
    
    // 修改：使用版本服务进行检查
    Future.delayed(const Duration(seconds: 2), _checkVersion);
  }

  @override
  void dispose() {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      windowManager.removeListener(this);
    }
    _fabAnimController.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // 显示选择对话框
    final shouldExit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).confirmExit),
        content: Text(AppLocalizations.of(context).confirmExitDesc),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context, false);
              // 隐藏窗口到系统托盘
              await windowManager.hide();
            },
            child: Text(AppLocalizations.of(context).minimize),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(AppLocalizations.of(context).exitApp),
          ),
        ],
      ),
    );
    
    if (shouldExit == true) {
      // 显示退出进度对话框
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => WillPopScope(
            onWillPop: () async => false,
            child: AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(AppLocalizations.of(context).disconnecting),
                ],
              ),
            ),
          ),
        );
      }
      
      // 清理资源
      try {
        final connectionProvider = context.read<ConnectionProvider>();
        
        // 如果已连接，先断开连接
        if (connectionProvider.isConnected) {
          await connectionProvider.disconnect();
        }
        
        // 确保V2Ray进程被终止
        await V2RayService.stop();
        
        // 清理系统代理设置
        await ProxyService.disableSystemProxy();
        
      } catch (e) {
        print('清理资源时出错: $e');
      } finally {
        // 销毁窗口并退出应用
        await windowManager.destroy();
        exit(0);
      }
    }
  }
  
  // 修改：使用版本服务进行版本检查
  Future<void> _checkVersion() async {
    try {
      final versionService = VersionService();
      final result = await versionService.checkVersion();
      
      if (result.hasUpdate && result.versionInfo != null) {
        // 如果不是强制更新，检查是否应该显示提示
        if (!result.isForceUpdate) {
          final shouldShow = await versionService.shouldShowUpdatePrompt();
          if (!shouldShow) return;
        }
        
        // 显示更新对话框
        if (mounted) {
          _showUpdateDialog(result.versionInfo!, result.isForceUpdate);
        }
      }
    } catch (e) {
      print('版本检查失败: $e');
    }
  }
  
  // 修改：优化更新对话框，支持多平台 - 使用AppConfig
  void _showUpdateDialog(VersionInfo versionInfo, bool isForceUpdate) {
    final l10n = AppLocalizations.of(context);
    
    showDialog(
      context: context,
      barrierDismissible: !isForceUpdate, // 强制更新不可关闭
      builder: (context) => WillPopScope(
        onWillPop: () async => !isForceUpdate, // 强制更新不可返回
        child: AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.system_update, color: Colors.blue),
              const SizedBox(width: 8),
              Text(isForceUpdate ? '重要更新' : '发现新版本'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '版本 ${versionInfo.version}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (isForceUpdate)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning, color: Colors.orange, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '此版本包含重要更新，需要立即升级',
                          style: TextStyle(color: Colors.orange),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const Text('更新内容：', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(versionInfo.updateContent),
            ],
          ),
          actions: [
            if (!isForceUpdate)
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  // 记录提示时间
                  await VersionService().recordUpdatePrompt();
                },
                child: const Text('稍后提醒'),
              ),
            // 根据平台显示不同的更新按钮
            _buildUpdateButton(versionInfo, isForceUpdate),
          ],
        ),
      ),
    );
  }
  
  // 新增：构建平台特定的更新按钮 - 使用AppConfig
  Widget _buildUpdateButton(VersionInfo versionInfo, bool isForceUpdate) {
    // Android平台 - 下载APK
    if (Platform.isAndroid) {
      return Consumer<DownloadProvider>(
        builder: (context, provider, child) {
          if (provider.isDownloading) {
            // 下载中显示进度
            return Container(
              width: 120,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: provider.progress),
                  const SizedBox(height: 4),
                  Text('${(provider.progress * 100).toStringAsFixed(0)}%'),
                ],
              ),
            );
          }
          
          return ElevatedButton(
            onPressed: () async {
              // 下载APK
              final filePath = await provider.downloadApk(versionInfo.getPlatformDownloadUrl());
              
              if (filePath != null) {
                // 尝试使用url_launcher安装
                final uri = Uri.file(filePath);
                
                // 优先尝试intent方式（Android专用）
                final intentUri = Uri(
                  scheme: 'intent',
                  path: filePath,
                  queryParameters: {
                    'action': 'android.intent.action.VIEW',
                    'type': 'application/vnd.android.package-archive',
                    'flags': '0x10000000', // FLAG_ACTIVITY_NEW_TASK
                  },
                );
                
                bool launched = false;
                
                // 先尝试intent方式
                if (await canLaunchUrl(intentUri)) {
                  try {
                    await launchUrl(intentUri);
                    launched = true;
                  } catch (e) {
                    print('Intent方式启动失败: $e');
                  }
                }
                
                // 如果intent失败，尝试file协议
                if (!launched && await canLaunchUrl(uri)) {
                  try {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                    launched = true;
                  } catch (e) {
                    print('File协议启动失败: $e');
                  }
                }
                
                // 如果都失败，提示手动安装
                if (!launched && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('请手动安装APK文件：\n$filePath'),
                      duration: const Duration(seconds: 10),
                      action: SnackBarAction(
                        label: '复制路径',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: filePath));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('路径已复制到剪贴板'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                }
              } else {
                // 下载失败，提供备用方案
                if (context.mounted) {
                  final shouldOpenBrowser = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('下载失败'),
                      content: Text('下载失败: ${provider.error ?? "未知错误"}\n\n是否打开浏览器下载？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('打开浏览器'),
                        ),
                      ],
                    ),
                  ) ?? false;
                  
                  if (shouldOpenBrowser) {
                    final uri = Uri.parse(versionInfo.getPlatformDownloadUrl());
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  }
                }
              }
            },
            child: const Text('立即更新'),
          );
        },
      );
    }
    
    // iOS平台 - 跳转App Store（使用AppConfig）
    if (Platform.isIOS) {
      return ElevatedButton(
        onPressed: () async {
          // 优先使用配置的App Store ID
          final appStoreUrl = AppConfig.getIosAppStoreUrl();
          if (appStoreUrl != null) {
            final uri = Uri.parse(appStoreUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return;
            }
          }
          
          // 如果没有配置App Store ID，使用下载链接
          final downloadUrl = versionInfo.getPlatformDownloadUrl();
          final uri = Uri.parse(downloadUrl);
          
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } else {
            // 如果无法打开链接，复制到剪贴板
            if (context.mounted) {
              await Clipboard.setData(ClipboardData(text: downloadUrl));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('下载链接已复制到剪贴板'),
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
        },
        child: const Text('前往App Store'),
      );
    }
    
    // macOS平台 - 跳转Mac App Store或下载链接（使用AppConfig）
    if (Platform.isMacOS) {
      return ElevatedButton(
        onPressed: () async {
          // 优先使用配置的Mac App Store ID
          final macAppStoreUrl = AppConfig.getMacAppStoreUrl();
          if (macAppStoreUrl != null) {
            final uri = Uri.parse(macAppStoreUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return;
            }
          }
          
          // 如果没有配置Mac App Store ID，使用下载链接
          final downloadUrl = versionInfo.getPlatformDownloadUrl();
          final uri = Uri.parse(downloadUrl);
          
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } else {
            // 如果无法打开链接，复制到剪贴板
            if (context.mounted) {
              await Clipboard.setData(ClipboardData(text: downloadUrl));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('下载链接已复制到剪贴板'),
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
        },
        child: macAppStoreUrl != null ? const Text('前往App Store') : const Text('前往下载'),
      );
    }
    
    // Windows、Linux - 跳转外部链接
    return ElevatedButton(
      onPressed: () async {
        final downloadUrl = versionInfo.getPlatformDownloadUrl();
        final uri = Uri.parse(downloadUrl);
        
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          // 如果无法打开链接，复制到剪贴板
          if (context.mounted) {
            await Clipboard.setData(ClipboardData(text: downloadUrl));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('下载链接已复制到剪贴板'),
                duration: Duration(seconds: 3),
              ),
            );
          }
        }
      },
      child: const Text('前往下载'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _buildCustomAppBar(context, isDark),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _pages[_currentIndex],
      ),
      bottomNavigationBar: _buildBottomNavigationBar(context),
      floatingActionButton: _buildFloatingActionButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  // 自定义应用栏（包含窗口控制按钮）- 使用AppConfig
  PreferredSizeWidget? _buildCustomAppBar(BuildContext context, bool isDark) {
    // 移动平台不显示自定义应用栏
    if (kIsWeb || (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
      return null;
    }

    return PreferredSize(
      preferredSize: Size.fromHeight(AppConfig.customTitleBarHeight),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (details) {
          windowManager.startDragging();
        },
        child: Container(
          decoration: BoxDecoration(
            color: isDark 
              ? const Color(0xFF1E1E1E).withOpacity(0.8)
              : Colors.white.withOpacity(0.8),
          ),
          child: Row(
            children: [
              const SizedBox(width: 16),
              // 应用图标和标题
              Row(
                children: [
                  Image.asset(
                    'assets/images/logo.png',
                    width: 20,
                    height: 20,
                    errorBuilder: (context, error, stackTrace) {
                      return const Icon(Icons.shield, size: 20);
                    },
                  ),
                  const SizedBox(width: 8),
                  Text(
                    AppConfig.appName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // 窗口控制按钮
              Row(
                children: [
                  _WindowControlButton(
                    icon: Icons.remove,
                    onPressed: () => windowManager.minimize(),
                    isDark: isDark,
                  ),
                  _WindowControlButton(
                    icon: Icons.close,
                    onPressed: () => windowManager.close(),
                    isDark: isDark,
                    isClose: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
          _fabAnimController.forward(from: 0);
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home),
            label: l10n.home,
          ),
          NavigationDestination(
            icon: const Icon(Icons.dns_outlined),
            selectedIcon: const Icon(Icons.dns),
            label: l10n.servers,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l10n.settings,
          ),
        ],
        animationDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  Widget? _buildFloatingActionButton() {
    // 只在服务器页面显示FAB
    if (_currentIndex != 1) return null;

    return ScaleTransition(
      scale: _fabAnimation,
      child: FloatingActionButton(
        onPressed: () {
          _showAddServerDialog();
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAddServerDialog() {
    final l10n = AppLocalizations.of(context);
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => SingleChildScrollView(
            controller: scrollController,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      l10n.addServer,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // 快速添加选项
                    _buildQuickAddOptions(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

// 只包含需要修改的部分

// 在 _showAddServerDialog 方法中，修改 CloudflareTestDialog 的使用
Widget _buildQuickAddOptions() {
  final l10n = AppLocalizations.of(context);
  
  return Column(
    children: [
      _buildAddOption(
        icon: Icons.cloud,
        title: l10n.addFromCloudflare,
        subtitle: l10n.autoGetBestNodes,
        color: Colors.blue,
        onTap: () {
          Navigator.pop(context);
          // 显示Cloudflare测试对话框 - 修改：移除speed参数
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.cloud_download, color: Colors.blue),
                      const SizedBox(width: 8),
                      Text(l10n.addFromCloudflare),
                    ],
                  ),
                  // 诊断按钮
                  IconButton(
                    icon: const Icon(Icons.bug_report, size: 20),
                    tooltip: l10n.diagnosticTool,
                    onPressed: () {
                      CloudflareDiagnosticTool.showDiagnosticDialog(context);
                    },
                  ),
                ],
              ),
              content: const CloudflareTestDialog(),
            ),
          );
        },
      ),
      const SizedBox(height: 12),
      _buildAddOption(
        icon: Icons.edit,
        title: l10n.manualAdd,
        subtitle: l10n.inputServerInfo,
        color: Colors.green,
        onTap: () {
          Navigator.pop(context);
          // TODO: 显示手动添加对话框
        },
      ),
      const SizedBox(height: 12),
      _buildAddOption(
        icon: Icons.qr_code,
        title: l10n.scanQrCode,
        subtitle: l10n.importFromQrCode,
        color: Colors.orange,
        onTap: () {
          Navigator.pop(context);
          // TODO: 打开二维码扫描
        },
      ),
      const SizedBox(height: 12),
      _buildAddOption(
        icon: Icons.file_copy,
        title: l10n.importFromClipboard,
        subtitle: l10n.pasteServerConfig,
        color: Colors.purple,
        onTap: () {
          Navigator.pop(context);
          // TODO: 从剪贴板导入
        },
      ),
    ],
  );
}

  Widget _buildAddOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: color.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              size: 16,
              color: Colors.grey.shade400,
            ),
          ],
        ),
      ),
    );
  }
}

// 窗口控制按钮组件
class _WindowControlButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final bool isDark;
  final bool isClose;

  const _WindowControlButton({
    required this.icon,
    required this.onPressed,
    required this.isDark,
    this.isClose = false,
  });

  @override
  State<_WindowControlButton> createState() => _WindowControlButtonState();
}

class _WindowControlButtonState extends State<_WindowControlButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: AppConfig.customTitleBarHeight,
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.isClose
                    ? Colors.red
                    : (widget.isDark 
                        ? Colors.white.withOpacity(0.1)
                        : Colors.black.withOpacity(0.05))
                : Colors.transparent,
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: _isHovered && widget.isClose
                ? Colors.white
                : (widget.isDark ? Colors.white70 : Colors.black54),
          ),
        ),
      ),
    );
  }
}