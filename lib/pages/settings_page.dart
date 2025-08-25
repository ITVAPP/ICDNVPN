import 'dart:io'; 
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../services/autostart_service.dart';
import '../services/version_service.dart';  // 新增：引入版本服务
import '../services/ad_service.dart';  // 新增：引入广告服务
import '../services/v2ray_service.dart';  // 新增：引入V2Ray服务（用于获取应用列表）
import '../utils/log_service.dart';  // 新增：引入日志服务
import '../l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_config.dart';
import '../pages/privacy_policy_page.dart';  // 新增：引入隐私政策页面

// 字号常量定义
class FontSizes {
  static const double sectionTitle = 18.0;     // 分组标题
  static const double settingTitle = 16.0;     // 设置项标题
  static const double settingSubtitle = 14.0;  // 设置项副标题（描述）
  static const double dialogTitle = 16.0;      // 对话框标题
  static const double dialogOption = 14.0;     // 对话框选项
  static const double description = 14.0;      // 一般描述文字
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _autoStart = false;
  // 修改：使用AppConfig替代硬编码值
  
  // 新增：版本状态
  bool _isCheckingVersion = false;
  VersionInfo? _latestVersion;

  @override
  void initState() {
    super.initState();
    _loadAutoStartStatus();
    _checkVersionStatus();  // 新增：初始化时检查版本状态
  }
  
void _updateConnectionProviderLocale() {
  // 延迟执行，确保语言切换完成
  Future.delayed(const Duration(milliseconds: 100), () {
    if (mounted) {
      final connectionProvider = context.read<ConnectionProvider>();
      connectionProvider.updateLocalizedStrings(context);
    }
  });
}

  Future<void> _loadAutoStartStatus() async {
    final enabled = AutoStartService.isAutoStartEnabled();
    setState(() {
      _autoStart = enabled;
    });
  }
  
  // 新增：检查版本状态（使用缓存）
  Future<void> _checkVersionStatus() async {
    final versionService = VersionService();
    if (versionService.hasNewVersion && versionService.latestVersionInfo != null) {
      setState(() {
        _latestVersion = versionService.latestVersionInfo;
      });
    }
  }
  
  // 新增：手动检查更新
  Future<void> _manualCheckUpdate() async {
    if (_isCheckingVersion) return;
    
    setState(() {
      _isCheckingVersion = true;
    });
    
    final l10n = AppLocalizations.of(context);
    
    try {
      final versionService = VersionService();
      final result = await versionService.checkVersion(forceCheck: true);
      
      if (result.hasUpdate && result.versionInfo != null) {
        // 更新状态
        setState(() {
          _latestVersion = result.versionInfo;
        });
        
        // 显示更新对话框
        if (mounted) {
          _showUpdateDialog(result.versionInfo!, result.isForceUpdate);
        }
      } else {
        // 已是最新版本
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.alreadyLatestVersion),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      // 检查失败
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.checkUpdateFailedError(e.toString())),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingVersion = false;
        });
      }
    }
  }
  
  // 新增：显示更新对话框（与main.dart类似）
  void _showUpdateDialog(VersionInfo versionInfo, bool isForceUpdate) {
    final l10n = AppLocalizations.of(context);
    
    showDialog(
      context: context,
      barrierDismissible: !isForceUpdate,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Colors.blue),
            const SizedBox(width: 8),
            Text(
              isForceUpdate ? l10n.importantUpdate : l10n.newVersionFound,
              style: const TextStyle(fontSize: FontSizes.dialogTitle),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.versionFormat(versionInfo.version),
              style: const TextStyle(
                fontSize: FontSizes.settingTitle,
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
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.orange, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.forceUpdateNotice,
                        style: const TextStyle(
                          color: Colors.orange,
                          fontSize: FontSizes.description,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              l10n.updateContent, 
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: FontSizes.description,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              versionInfo.updateContent,
              style: const TextStyle(fontSize: FontSizes.description),
            ),
          ],
        ),
        actions: [
          if (!isForceUpdate)
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await VersionService().recordUpdatePrompt();
              },
              child: Text(
                l10n.remindLater,
                style: const TextStyle(fontSize: FontSizes.description),
              ),
            ),
          ElevatedButton(
            onPressed: () async {
              final uri = Uri.parse(versionInfo.getPlatformDownloadUrl());
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: Text(
              l10n.goToDownload,
              style: const TextStyle(fontSize: FontSizes.description),
            ),
          ),
        ],
      ),
    );
  }

  // 获取应用白名单概要文字
  String _getAppWhitelistSummary(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final connectionProvider = context.watch<ConnectionProvider>();
    final count = connectionProvider.allowedApps.length;
    
    if (count == 0) {
      return l10n.noAppsSelected;
    } else {
      return l10n.appsSelected(count);
    }
  }

  // 显示应用选择对话框
  Future<void> _showAppSelectorDialog(BuildContext context) async {
    final connectionProvider = context.read<ConnectionProvider>();
    final l10n = AppLocalizations.of(context);
    
    // 只在Android/iOS平台显示
    if (!Platform.isAndroid && !Platform.isIOS) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.notSupportedOnThisPlatform),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    
    // 如果已连接，不允许修改
    if (connectionProvider.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.cannotModifyWhileConnected),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    
    // 显示应用选择对话框
    final selectedApps = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AppSelectorDialog(
        selectedApps: List<String>.from(connectionProvider.allowedApps),
      ),
    );
    
    // 如果用户选择了应用，保存
    if (selectedApps != null) {
      await connectionProvider.setAllowedApps(selectedApps);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    
    return Scaffold(
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.only(top: 60), // 为自定义标题栏留出空间
          children: [
            // 通用设置
            _SectionHeader(title: l10n.generalSettings),
            _SettingSwitch(
              title: l10n.autoStart,
              subtitle: l10n.autoStartDesc,
              value: _autoStart,
              onChanged: (value) async {
                final success = await AutoStartService.setAutoStart(value);
                if (success) {
                  setState(() {
                    _autoStart = value;
                  });
                } else {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.operationFailed),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                }
              },
            ),
            _SettingSwitch(
              title: l10n.autoConnect,
              subtitle: l10n.autoConnectDesc,
              value: Provider.of<ConnectionProvider>(context).autoConnect,
              onChanged: (value) {
                Provider.of<ConnectionProvider>(context, listen: false)
                    .setAutoConnect(value);
              },
            ),
            
            // 修改：移除平台判断，所有平台都显示全局代理开关
            Consumer<ConnectionProvider>(
              builder: (context, connectionProvider, child) {
                return _SettingSwitch(
                  title: l10n.globalProxy,  // 修改：使用globalProxy
                  subtitle: l10n.globalProxyDesc,  // 修改：使用globalProxyDesc
                  value: connectionProvider.globalProxy,  // 修改：使用globalProxy
                  onChanged: connectionProvider.isConnected 
                    ? null  // 连接时禁用切换
                    : (value) {
                        connectionProvider.setGlobalProxy(value);  // 修改：调用setGlobalProxy
                      },
                );
              },
            ),
            
            // 新增：应用白名单设置（仅Android/iOS显示）
            if (Platform.isAndroid || Platform.isIOS)
              Consumer<ConnectionProvider>(
                builder: (context, connectionProvider, child) {
                  return _SettingTile(
                    title: l10n.appWhitelist,
                    subtitle: _getAppWhitelistSummary(context),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: connectionProvider.isConnected 
                        ? theme.disabledColor 
                        : null,
                    ),
                    onTap: connectionProvider.isConnected
                      ? () {
                          // 连接时点击，显示提示
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.cannotModifyWhileConnected),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      : () => _showAppSelectorDialog(context),
                  );
                },
              ),
            
            // 外观设置
            const _SectionDivider(),
            _SettingTile(
              title: l10n.language,
              subtitle: _getLanguageName(context),
              onTap: () => _showLanguageDialog(context),
            ),
            _SettingTile(
              title: l10n.theme,
              subtitle: _getThemeName(context),
              onTap: () => _showThemeDialog(context),
            ),
            
            // 关于
            const _SectionDivider(),
            _SectionHeader(title: l10n.about),
            // 修改：版本信息行（使用AppConfig）
            ListTile(
              dense: true,
              title: Text(
                l10n.currentVersion,
                style: const TextStyle(fontSize: FontSizes.settingTitle),
              ),
              subtitle: Text(
                'v${AppConfig.currentVersion}',  // 使用AppConfig
                style: const TextStyle(fontSize: FontSizes.settingSubtitle),
              ),
              trailing: _buildVersionTrailing(l10n),
            ),
            _SettingTile(
              title: l10n.officialWebsite,
              subtitle: AppConfig.officialWebsite,  // 使用AppConfig
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () async {
                final uri = Uri.parse(AppConfig.officialWebsite);  // 使用AppConfig
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
            _SettingTile(
              title: l10n.contactEmail,
              subtitle: AppConfig.contactEmail,  // 使用AppConfig
              trailing: const Icon(Icons.email_outlined, size: 18),
              onTap: () async {
                final uri = Uri(
                  scheme: 'mailto',
                  path: AppConfig.contactEmail,  // 使用AppConfig
                );
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri);
                }
              },
            ),
            _SettingTile(
              title: l10n.privacyPolicy,
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                // 修改：导航到隐私政策页面
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PrivacyPolicyPage(),
                  ),
                );
              },
            ),
            
            const SizedBox(height: 20),
            // 清除缓存按钮 - 修改：优化样式
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ElevatedButton.icon(
                onPressed: () async {
                  // 显示确认对话框
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(
                        l10n.clearCache,
                        style: const TextStyle(fontSize: FontSizes.dialogTitle),
                      ),
                      content: Text(
                        l10n.clearCacheConfirm,
                        style: const TextStyle(fontSize: FontSizes.description),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(
                            l10n.cancel,
                            style: const TextStyle(fontSize: FontSizes.description),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          style: TextButton.styleFrom(foregroundColor: Colors.red),
                          child: Text(
                            l10n.clearCache,
                            style: const TextStyle(fontSize: FontSizes.description),
                          ),
                        ),
                      ],
                    ),
                  ) ?? false;
                  
                  if (!confirmed) return;
                  
                  // 执行清除操作
                  try {
                    // 检查是否正在连接中
                    final connectionProvider = context.read<ConnectionProvider>();
                    if (connectionProvider.isConnected) {
                      // 提示用户将断开连接
                      final proceedWithDisconnect = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(
                            l10n.tip,
                            style: const TextStyle(fontSize: FontSizes.dialogTitle),
                          ),
                          content: Text(
                            l10n.clearCacheDisconnectWarning,
                            style: const TextStyle(fontSize: FontSizes.description),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(
                                l10n.cancel,
                                style: const TextStyle(fontSize: FontSizes.description),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              style: TextButton.styleFrom(foregroundColor: Colors.orange),
                              child: Text(
                                l10n.continue_,
                                style: const TextStyle(fontSize: FontSizes.description),
                              ),
                            ),
                          ],
                        ),
                      ) ?? false;
                      
                      if (!proceedWithDisconnect) return;
                      
                      // 先断开连接
                      await connectionProvider.disconnect();
                    }
                    
                    // 显示进度对话框
                    if (!mounted) return;
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (context) => AlertDialog(
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              l10n.clearingCache,
                              style: const TextStyle(fontSize: FontSizes.description),
                            ),
                          ],
                        ),
                      ),
                    );
                    
                    // 添加延迟，让进度对话框有时间显示
                    await Future.delayed(const Duration(milliseconds: 100));
                    
                    // 1. 清除所有日志文件
                    await LogService.instance.clearAllLogs();
                    
                    // 2. 清除SharedPreferences
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.clear();
                    
                    // 3. 清除广告缓存（如果有）
                    if (mounted) {
                      final adService = context.read<AdService>();
                      // 重新初始化广告服务以清除缓存
                      await adService.initialize();
                    }
                    
                    // 4. 重置各个Provider的状态
                    if (mounted) {
                      // 重置服务器列表（不自动刷新，避免立即网络请求）
                      final serverProvider = context.read<ServerProvider>();
                      await serverProvider.clearAllServers();
                      
                      // 重置连接状态
                      context.read<ConnectionProvider>().setCurrentServer(null);
                      
                      // 重置主题
                      context.read<ThemeProvider>().setThemeMode(ThemeMode.system);
                      
                      // 重置语言
                      context.read<LocaleProvider>().clearLocale();
                      
                      // 清除版本检查缓存
                      final versionPrefs = await SharedPreferences.getInstance();
                      await versionPrefs.remove('last_version_check');
                      await versionPrefs.remove('last_update_prompt');
                    }
                    
                    // 关闭进度对话框
                    if (mounted) {
                      Navigator.of(context).pop();
                    }
                    
                    // 修改：简化成功提示，只显示两行文字，去掉操作按钮
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.cacheCleared,
                                style: const TextStyle(
                                  fontSize:  FontSizes.dialogTitle,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l10n.cacheDetails,
                                style: TextStyle(
                                  fontSize: FontSizes.dialogOption,
                                  color: Colors.white.withOpacity(0.8),
                                ),
                              ),
                            ],
                          ),
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    }
                  } catch (e) {
                    // 关闭进度对话框（如果还在显示）
                    if (mounted) {
                      // 使用rootNavigator确保关闭正确的对话框
                      Navigator.of(context, rootNavigator: true).pop();
                    }
                    
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${l10n.operationFailed}: $e'),
                          backgroundColor: Colors.red,
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: Text(
                  l10n.clearCache,
                  style: const TextStyle(
                    fontSize: FontSizes.description,
                    fontWeight: FontWeight.bold,  // 修改：文字加粗
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  // 修改：优化浅色主题下的背景色
                  backgroundColor: theme.brightness == Brightness.light
                      ? theme.primaryColor  // 浅色主题使用主题色
                      : null,  // 深色主题使用默认背景色
                  foregroundColor: theme.brightness == Brightness.light
                      ? Colors.white  // 浅色主题使用白色文字
                      : null,  // 深色主题使用默认文字色
                ),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
  
  // 新增：构建版本状态显示
  Widget _buildVersionTrailing(AppLocalizations l10n) {
    // 如果正在检查
    if (_isCheckingVersion) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    
    // 如果有新版本
    if (_latestVersion != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.withOpacity(0.5)),
        ),
        child: InkWell(
          onTap: _manualCheckUpdate,
          borderRadius: BorderRadius.circular(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.new_releases, size: 16, color: Colors.orange),
              const SizedBox(width: 4),
              Text(
                l10n.newVersionFormat(_latestVersion!.version),
                style: const TextStyle(
                  fontSize: FontSizes.description,
                  color: Colors.orange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }
    
    // 默认显示检查更新按钮
    return TextButton(
      onPressed: _manualCheckUpdate,
      child: Text(
        l10n.checkUpdate,
        style: const TextStyle(fontSize: FontSizes.description),
      ),
    );
  }

  String _getLanguageName(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final languageNames = {
      'en': 'English',
      'zh': locale.countryCode == 'TW' ? '繁體中文' : '简体中文',
      'ja': '日本語',
      'ko': '한국어',
      'es': 'Español',
      'fr': 'Français',
      'de': 'Deutsch',
      'ru': 'Русский',
      'ar': 'العربية',
    };
    return languageNames[locale.languageCode] ?? locale.languageCode;
  }

  String _getThemeName(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final themeMode = Provider.of<ThemeProvider>(context).themeMode;
    
    switch (themeMode) {
      case ThemeMode.light:
        return l10n.lightTheme;
      case ThemeMode.dark:
        return l10n.darkTheme;
      case ThemeMode.system:
      default:
        return l10n.systemTheme;
    }
  }

  void _showLanguageDialog(BuildContext context) {
    final localeProvider = Provider.of<LocaleProvider>(context, listen: false);
    final currentLocale = Localizations.localeOf(context);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          AppLocalizations.of(context).language,
          style: const TextStyle(fontSize: FontSizes.dialogTitle),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LanguageOption(
              title: 'English',
              locale: const Locale('en', 'US'),
              isSelected: currentLocale.languageCode == 'en',
              onTap: () {
                localeProvider.setLocale(const Locale('en', 'US'));
                Navigator.pop(context);
                _updateConnectionProviderLocale();
              },
            ),
            _LanguageOption(
              title: '简体中文',
              locale: const Locale('zh', 'CN'),
              isSelected: currentLocale.languageCode == 'zh' && currentLocale.countryCode == 'CN',
              onTap: () {
                localeProvider.setLocale(const Locale('zh', 'CN'));
                Navigator.pop(context);
                _updateConnectionProviderLocale();
              },
            ),
            _LanguageOption(
              title: '繁體中文',
              locale: const Locale('zh', 'TW'),
              isSelected: currentLocale.languageCode == 'zh' && currentLocale.countryCode == 'TW',
              onTap: () {
                localeProvider.setLocale(const Locale('zh', 'TW'));
                Navigator.pop(context);
                _updateConnectionProviderLocale();
              },
            ),
            _LanguageOption(
              title: '日本語',
              locale: const Locale('ja', 'JP'),
              isSelected: currentLocale.languageCode == 'ja',
              onTap: () {
                localeProvider.setLocale(const Locale('ja', 'JP'));
                Navigator.pop(context);
                _updateConnectionProviderLocale();
              },
            ),
            _LanguageOption(
              title: '한국어',
              locale: const Locale('ko', 'KR'),
              isSelected: currentLocale.languageCode == 'ko',
              onTap: () {
                localeProvider.setLocale(const Locale('ko', 'KR'));
                Navigator.pop(context);
                _updateConnectionProviderLocale();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showThemeDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final currentThemeMode = themeProvider.themeMode;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          l10n.theme,
          style: const TextStyle(fontSize: FontSizes.dialogTitle),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ThemeOption(
              title: l10n.systemTheme,
              icon: Icons.brightness_auto,
              isSelected: currentThemeMode == ThemeMode.system,
              onTap: () {
                themeProvider.setThemeMode(ThemeMode.system);
                Navigator.pop(context);
              },
            ),
            _ThemeOption(
              title: l10n.lightTheme,
              icon: Icons.light_mode,
              isSelected: currentThemeMode == ThemeMode.light,
              onTap: () {
                themeProvider.setThemeMode(ThemeMode.light);
                Navigator.pop(context);
              },
            ),
            _ThemeOption(
              title: l10n.darkTheme,
              icon: Icons.dark_mode,
              isSelected: currentThemeMode == ThemeMode.dark,
              onTap: () {
                themeProvider.setThemeMode(ThemeMode.dark);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// 应用选择对话框
class _AppSelectorDialog extends StatefulWidget {
  final List<String> selectedApps;
  
  const _AppSelectorDialog({
    required this.selectedApps,
  });

  @override
  State<_AppSelectorDialog> createState() => _AppSelectorDialogState();
}

class _AppSelectorDialogState extends State<_AppSelectorDialog> {
  List<Map<String, dynamic>> _allApps = [];
  List<Map<String, dynamic>> _filteredApps = [];
  List<String> _selectedApps = [];
  String _searchQuery = '';
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedApps = List<String>.from(widget.selectedApps);
    _loadApps();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    try {
      final apps = await V2RayService.getInstalledApps();
      
      // 过滤系统应用，只显示用户应用
      final userApps = apps.where((app) => 
        app['isSystemApp'] != true
      ).toList();
      
      // 按应用名排序
      userApps.sort((a, b) => 
        (a['appName'] as String).toLowerCase().compareTo(
          (b['appName'] as String).toLowerCase()
        )
      );
      
      setState(() {
        _allApps = userApps;
        _filteredApps = userApps;
        _isLoading = false;
      });
    } catch (e) {
      LogService.instance.error('加载应用列表失败', tag: 'AppSelector', error: e);
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _filterApps(String query) {
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _filteredApps = _allApps;
      } else {
        final lowerQuery = query.toLowerCase();
        _filteredApps = _allApps.where((app) {
          final appName = (app['appName'] as String).toLowerCase();
          final packageName = (app['packageName'] as String).toLowerCase();
          return appName.contains(lowerQuery) || packageName.contains(lowerQuery);
        }).toList();
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedApps.length == _filteredApps.length) {
        // 如果已全选，则取消全选
        _selectedApps.clear();
      } else {
        // 全选当前过滤的应用
        _selectedApps = _filteredApps
          .map((app) => app['packageName'] as String)
          .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    
    return AlertDialog(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.apps, size: 24),
              const SizedBox(width: 8),
              Text(
                l10n.selectApps,
                style: const TextStyle(fontSize: FontSizes.dialogTitle),
              ),
              const Spacer(),
              // 全选/取消全选按钮
              TextButton(
                onPressed: _isLoading ? null : _toggleSelectAll,
                child: Text(
                  _selectedApps.length == _filteredApps.length
                    ? l10n.deselectAll
                    : l10n.selectAll,
                  style: const TextStyle(fontSize: FontSizes.description),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 搜索框
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.searchApps,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      _filterApps('');
                    },
                  )
                : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onChanged: _filterApps,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _filteredApps.isEmpty
            ? Center(
                child: Text(
                  _searchQuery.isEmpty 
                    ? l10n.noAppsFound
                    : l10n.noSearchResults,
                  style: TextStyle(
                    fontSize: FontSizes.description,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              )
            : ListView.builder(
                itemCount: _filteredApps.length,
                itemBuilder: (context, index) {
                  final app = _filteredApps[index];
                  final packageName = app['packageName'] as String;
                  final appName = app['appName'] as String;
                  final isSelected = _selectedApps.contains(packageName);
                  
                  return CheckboxListTile(
                    value: isSelected,
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selectedApps.add(packageName);
                        } else {
                          _selectedApps.remove(packageName);
                        }
                      });
                    },
                    title: Text(
                      appName,
                      style: const TextStyle(fontSize: FontSizes.settingTitle),
                    ),
                    subtitle: Text(
                      packageName,
                      style: TextStyle(
                        fontSize: FontSizes.description - 1,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                    dense: true,
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.cancel,
            style: const TextStyle(fontSize: FontSizes.description),
          ),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _selectedApps),
          child: Text(
            l10n.save,
            style: const TextStyle(fontSize: FontSizes.description),
          ),
        ),
      ],
    );
  }
}

// 分节标题组件 - 修复深色主题下的颜色问题
class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: FontSizes.sectionTitle,
          fontWeight: FontWeight.bold,
          // 修复：使用主题的文字颜色，而不是固定的主题色
          color: theme.textTheme.titleMedium?.color ?? theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}

// 分节分隔线
class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Divider(height: 1),
    );
  }
}

// 设置项组件
class _SettingTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _SettingTile({
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(
        title, 
        style: const TextStyle(fontSize: FontSizes.settingTitle),
      ),
      subtitle: subtitle != null ? Text(
        subtitle!, 
        style: const TextStyle(fontSize: FontSizes.settingSubtitle),
      ) : null,
      trailing: trailing,
      onTap: onTap,
    );
  }
}

// 开关设置项组件
class _SettingSwitch extends StatefulWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;  // 修改：允许为null以支持禁用状态

  const _SettingSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_SettingSwitch> createState() => _SettingSwitchState();
}

class _SettingSwitchState extends State<_SettingSwitch> {
  late bool _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(covariant _SettingSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _value = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      title: Text(
        widget.title,
        style: const TextStyle(fontSize: FontSizes.settingTitle),
      ),
      subtitle: Text(
        widget.subtitle,
        style: const TextStyle(fontSize: FontSizes.settingSubtitle),
      ),
      value: _value,
      onChanged: widget.onChanged != null 
        ? (value) {
            setState(() {
              _value = value;
            });
            widget.onChanged!(value);
          }
        : null,  // 当onChanged为null时，开关会自动禁用
    );
  }
}

// 语言选项组件
class _LanguageOption extends StatelessWidget {
  final String title;
  final Locale locale;
  final bool isSelected;
  final VoidCallback onTap;

  const _LanguageOption({
    required this.title,
    required this.locale,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 浅色主题使用主色（蓝色），深色主题使用文字颜色
    final isDarkMode = theme.brightness == Brightness.dark;
    final iconColor = isDarkMode 
        ? (theme.textTheme.bodyLarge?.color ?? theme.colorScheme.onSurface)
        : theme.primaryColor;
    
    return ListTile(
      dense: true,
      title: Text(
        title,
        style: const TextStyle(fontSize: FontSizes.dialogOption),
      ),
      trailing: isSelected
          ? Icon(Icons.check, color: iconColor)
          : null,
      onTap: onTap,
    );
  }
}

// 主题选项组件
class _ThemeOption extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeOption({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 浅色主题使用主色（蓝色），深色主题使用文字颜色
    final isDarkMode = theme.brightness == Brightness.dark;
    final iconColor = isDarkMode 
        ? (theme.textTheme.bodyLarge?.color ?? theme.colorScheme.onSurface)
        : theme.primaryColor;
    
    return ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text(
        title,
        style: const TextStyle(fontSize: FontSizes.dialogOption),
      ),
      trailing: isSelected
          ? Icon(Icons.check, color: iconColor)
          : null,
      onTap: onTap,
    );
  }
}
