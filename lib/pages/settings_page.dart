import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../services/autostart_service.dart';
import '../l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _autoStart = false;
  final String _version = 'v1.0.1';
  final String _officialWebsite = 'https://www.example.com';
  final String _contactEmail = 'abc@abc.com';

  @override
  void initState() {
    super.initState();
    _loadAutoStartStatus();
  }

  Future<void> _loadAutoStartStatus() async {
    final enabled = AutoStartService.isAutoStartEnabled();
    setState(() {
      _autoStart = enabled;
    });
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
            
            // 网络设置
            const _SectionDivider(),
            _SectionHeader(title: l10n.networkSettings),
            _SettingTile(
              title: l10n.proxyMode,
              subtitle: l10n.globalProxy,
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                // TODO: 打开代理模式选择
              },
            ),
            _SettingTile(
              title: l10n.routeSettings,
              subtitle: l10n.configureRules,
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                // TODO: 打开路由设置
              },
            ),
            
            // 关于
            const _SectionDivider(),
            _SectionHeader(title: l10n.about),
            // 版本信息行（包含检查更新按钮）
            ListTile(
              title: Text(l10n.currentVersion),
              subtitle: Text(_version),
              trailing: TextButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.alreadyLatestVersion),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                child: Text(l10n.checkUpdate),
              ),
            ),
            _SettingTile(
              title: l10n.officialWebsite,
              subtitle: _officialWebsite,
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () async {
                final uri = Uri.parse(_officialWebsite);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
            _SettingTile(
              title: l10n.contactEmail,
              subtitle: _contactEmail,
              trailing: const Icon(Icons.email_outlined, size: 18),
              onTap: () async {
                final uri = Uri(
                  scheme: 'mailto',
                  path: _contactEmail,
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
                // TODO: 打开隐私政策
              },
            ),
            
            const SizedBox(height: 20),
            // 清除缓存按钮
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ElevatedButton.icon(
                onPressed: () async {
                  // 显示确认对话框
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(l10n.clearCache),
                      content: const Text('将清除所有缓存数据，包括服务器列表、设置等。确定要继续吗？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(l10n.disconnect), // 取消
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          style: TextButton.styleFrom(foregroundColor: Colors.red),
                          child: Text(l10n.clearCache),
                        ),
                      ],
                    ),
                  ) ?? false;
                  
                  if (!confirmed) return;
                  
                  // 执行清除操作
                  try {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.clear(); // 清除所有存储的数据
                    
                    // 重置各个Provider的状态
                    if (mounted) {
                      // 重新获取服务器列表
                      context.read<ServerProvider>().refreshFromCloudflare();
                      // 重置连接状态
                      context.read<ConnectionProvider>().setCurrentServer(null);
                      // 重置主题
                      context.read<ThemeProvider>().setThemeMode(ThemeMode.system);
                      // 重置语言
                      context.read<LocaleProvider>().clearLocale();
                    }
                    
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(l10n.cacheCleared),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${l10n.operationFailed}: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: Text(l10n.clearCache),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
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
        title: Text(AppLocalizations.of(context).language),
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
              },
            ),
            _LanguageOption(
              title: '简体中文',
              locale: const Locale('zh', 'CN'),
              isSelected: currentLocale.languageCode == 'zh' && currentLocale.countryCode == 'CN',
              onTap: () {
                localeProvider.setLocale(const Locale('zh', 'CN'));
                Navigator.pop(context);
              },
            ),
            _LanguageOption(
              title: '繁體中文',
              locale: const Locale('zh', 'TW'),
              isSelected: currentLocale.languageCode == 'zh' && currentLocale.countryCode == 'TW',
              onTap: () {
                localeProvider.setLocale(const Locale('zh', 'TW'));
                Navigator.pop(context);
              },
            ),
            _LanguageOption(
              title: '日本語',
              locale: const Locale('ja', 'JP'),
              isSelected: currentLocale.languageCode == 'ja',
              onTap: () {
                localeProvider.setLocale(const Locale('ja', 'JP'));
                Navigator.pop(context);
              },
            ),
            _LanguageOption(
              title: '한국어',
              locale: const Locale('ko', 'KR'),
              isSelected: currentLocale.languageCode == 'ko',
              onTap: () {
                localeProvider.setLocale(const Locale('ko', 'KR'));
                Navigator.pop(context);
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
        title: Text(l10n.theme),
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

// 分节标题组件
class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).primaryColor,
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
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
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
  final ValueChanged<bool> onChanged;

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
      title: Text(widget.title),
      subtitle: Text(widget.subtitle),
      value: _value,
      onChanged: (value) {
        setState(() {
          _value = value;
        });
        widget.onChanged(value);
      },
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
    return ListTile(
      title: Text(title),
      trailing: isSelected
          ? Icon(Icons.check, color: Theme.of(context).primaryColor)
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
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: isSelected
          ? Icon(Icons.check, color: Theme.of(context).primaryColor)
          : null,
      onTap: onTap,
    );
  }
}