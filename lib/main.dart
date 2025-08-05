import 'dart:io' show Platform, exit;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'providers/app_provider.dart';
import 'pages/home_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'services/cloudflare_test_service.dart';
import 'utils/diagnostic_tool.dart';
import 'services/v2ray_service.dart';
import 'services/proxy_service.dart';
import 'services/ad_service.dart';
import 'l10n/app_localizations.dart';

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
  
  // 初始化窗口管理器（仅桌面平台）
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();
    
    // 等待窗口准备就绪
    await windowManager.waitUntilReadyToShow();
    
    // 设置窗口选项
    WindowOptions windowOptions = const WindowOptions(
      size: Size(400, 720), // 增加默认高度以适应内容
      minimumSize: Size(380, 650),
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
        ChangeNotifierProvider(create: (_) => AdService()..initialize()), // 新增：广告服务
      ],
      child: Consumer2<ThemeProvider, LocaleProvider>(
        builder: (context, themeProvider, localeProvider, child) {
          return MaterialApp(
            title: 'CFVPN',
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

  // 自定义应用栏（包含窗口控制按钮）
  PreferredSizeWidget? _buildCustomAppBar(BuildContext context, bool isDark) {
    // 移动平台不显示自定义应用栏
    if (kIsWeb || (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
      return null;
    }

    return PreferredSize(
      preferredSize: const Size.fromHeight(40),
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
                    'CFVPN',
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
            // 显示Cloudflare测试对话框 - 修改：直接使用CloudflareTestDialog
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
          height: 40,
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