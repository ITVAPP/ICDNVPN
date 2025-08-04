import 'package:flutter/material.dart';

// 本地化基类 - 使用Map存储翻译
class AppLocalizations {
  final Map<String, String> _translations;
  
  AppLocalizations(this._translations);
  
  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();
  
  static const List<Locale> supportedLocales = [
    Locale('zh', 'CN'),  // 中文作为第一个（默认）
    Locale('en', 'US'),
    Locale('zh', 'TW'),
    Locale('es', 'ES'),
    Locale('ru', 'RU'),
    Locale('ar', 'SA'),
  ];
  
  // 获取翻译，如果不存在则返回中文
  String _get(String key) {
    return _translations[key] ?? _zhCnTranslations[key] ?? key;
  }
  
  // 通用
  String get home => _get('home');
  String get servers => _get('servers');
  String get settings => _get('settings');
  String get disconnect => _get('disconnect');
  String get connected => _get('connected');
  String get disconnected => _get('disconnected');
  String get connecting => _get('connecting');
  String get disconnecting => _get('disconnecting');
  String get close => _get('close');
  
  // 主页
  String get clickToConnect => _get('clickToConnect');
  String get clickToDisconnect => _get('clickToDisconnect');
  String get currentServer => _get('currentServer');
  String get selectServer => _get('selectServer');
  String get upload => _get('upload');
  String get download => _get('download');
  String get autoSelectNode => _get('autoSelectNode');
  String get speedTest => _get('speedTest');
  String get refresh => _get('refresh');
  String get noNodesHint => _get('noNodesHint');
  
  // 服务器页面
  String get serverList => _get('serverList');
  String get addServer => _get('addServer');
  String get deleteServer => _get('deleteServer');
  String get testLatency => _get('testLatency');
  String get sortAscending => _get('sortAscending');
  String get sortDescending => _get('sortDescending');
  String get fromCloudflare => _get('fromCloudflare');
  String get noServers => _get('noServers');
  String get confirmDelete => _get('confirmDelete');
  String get latency => _get('latency');
  
  // 添加服务器
  String get addFromCloudflare => _get('addFromCloudflare');
  String get autoGetBestNodes => _get('autoGetBestNodes');
  String get manualAdd => _get('manualAdd');
  String get inputServerInfo => _get('inputServerInfo');
  String get scanQrCode => _get('scanQrCode');
  String get importFromQrCode => _get('importFromQrCode');
  String get importFromClipboard => _get('importFromClipboard');
  String get pasteServerConfig => _get('pasteServerConfig');
  String get diagnosticTool => _get('diagnosticTool');
  
  // 设置页面
  String get generalSettings => _get('generalSettings');
  String get networkSettings => _get('networkSettings');
  String get about => _get('about');
  String get autoStart => _get('autoStart');
  String get autoStartDesc => _get('autoStartDesc');
  String get autoConnect => _get('autoConnect');
  String get autoConnectDesc => _get('autoConnectDesc');
  String get proxyMode => _get('proxyMode');
  String get globalProxy => _get('globalProxy');
  String get routeSettings => _get('routeSettings');
  String get configureRules => _get('configureRules');
  String get currentVersion => _get('currentVersion');
  String get checkUpdate => _get('checkUpdate');
  String get officialWebsite => _get('officialWebsite');
  String get contactEmail => _get('contactEmail');
  String get privacyPolicy => _get('privacyPolicy');
  String get clearCache => _get('clearCache');
  String get cacheCleared => _get('cacheCleared');
  String get language => _get('language');
  String get theme => _get('theme');
  String get systemTheme => _get('systemTheme');
  String get lightTheme => _get('lightTheme');
  String get darkTheme => _get('darkTheme');
  
  // 消息
  String get operationFailed => _get('operationFailed');
  String get testingLatency => _get('testingLatency');
  String get gettingNodes => _get('gettingNodes');
  String get alreadyLatestVersion => _get('alreadyLatestVersion');
  String get serverAdded => _get('serverAdded');
  String get serverDeleted => _get('serverDeleted');
  
  // Cloudflare测试
  String get startTest => _get('startTest');
  String get testing => _get('testing');
  String get testCompleted => _get('testCompleted');
  String get testFailed => _get('testFailed');
  String get preparing => _get('preparing');
  
  // 新增的进度相关文本
  String get preparingTestEnvironment => _get('preparingTestEnvironment');
  String get initializing => _get('initializing');
  String get generatingTestIPs => _get('generatingTestIPs');
  String get samplingFromIPRanges => _get('samplingFromIPRanges');
  String get testingDelay => _get('testingDelay');
  String get testingDownloadSpeed => _get('testingDownloadSpeed');
  String get startingSpeedTest => _get('startingSpeedTest');
  String get foundQualityNodes => _get('foundQualityNodes');
  
  // 新增的测试相关文本
  String get noQualifiedNodes => _get('noQualifiedNodes');
  String get checkNetworkOrRequirements => _get('checkNetworkOrRequirements');
  String get noServersMetSpeedRequirement => _get('noServersMetSpeedRequirement');
  String get lowerSpeedRequirement => _get('lowerSpeedRequirement');
  String get nodeProgress => _get('nodeProgress');
  String get ipRanges => _get('ipRanges');
  
  // 诊断
  String get runDiagnostics => _get('runDiagnostics');
  String get fileCheck => _get('fileCheck');
  String get networkTest => _get('networkTest');
  String get systemInfo => _get('systemInfo');
  
  // 退出确认
  String get confirmExit => _get('confirmExit');
  String get confirmExitDesc => _get('confirmExitDesc');
  String get minimize => _get('minimize');
  String get exitApp => _get('exitApp');
  
  // 新增的节点获取相关文本
  String get gettingBestNodes => _get('gettingBestNodes');
  String get getNodesFailed => _get('getNodesFailed');
  String get noValidNodes => _get('noValidNodes');
  
  // 新增：连接断开相关文本
  String get connectionLost => _get('connectionLost');
  String get vpnDisconnected => _get('vpnDisconnected');
  
  // 带参数的文本格式化方法
  String samplingFromRanges(int count) {
    final template = _get('samplingFromIPRanges');
    return template.replaceAll('%s', count.toString());
  }
  
  String foundNodes(int count) {
    final template = _get('foundQualityNodes');
    return template.replaceAll('%s', count.toString());
  }
}

// 本地化委托
class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.contains(locale) ||
        AppLocalizations.supportedLocales.any((l) => l.languageCode == locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    Map<String, String> translations;
    
    // 根据语言代码选择翻译
    switch (locale.languageCode) {
      case 'zh':
        if (locale.countryCode == 'TW') {
          translations = _zhTwTranslations;
        } else {
          translations = _zhCnTranslations;
        }
        break;
      case 'en':
        translations = _enTranslations;
        break;
      case 'es':
        translations = _esTranslations;
        break;
      case 'ru':
        translations = _ruTranslations;
        break;
      case 'ar':
        translations = _arTranslations;
        break;
      default:
        translations = _zhCnTranslations; // 默认中文
    }
    
    return AppLocalizations(translations);
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) => false;
}

// 简体中文翻译（完整版，作为默认回退）
const Map<String, String> _zhCnTranslations = {
  // 通用
  'home': '首页',
  'servers': '服务器',
  'settings': '设置',
  'disconnect': '断开',
  'connected': '已连接',
  'disconnected': '未连接',
  'connecting': '正在连接...',
  'disconnecting': '正在断开...',
  'close': '关闭',
  
  // 主页
  'clickToConnect': '点击连接',
  'clickToDisconnect': '点击断开',
  'currentServer': '当前服务器',
  'selectServer': '选择服务器',
  'upload': '上传',
  'download': '下载',
  'autoSelectNode': '优选节点',
  'speedTest': '测速',
  'refresh': '刷新',
  'noNodesHint': '暂无节点，请先获取',
  
  // 服务器页面
  'serverList': '服务器列表',
  'addServer': '添加服务器',
  'deleteServer': '删除服务器',
  'testLatency': '测试延迟',
  'sortAscending': '延迟从低到高',
  'sortDescending': '延迟从高到低',
  'fromCloudflare': '从Cloudflare添加',
  'noServers': '暂无服务器',
  'confirmDelete': '确认删除',
  'latency': '延迟',
  
  // 添加服务器
  'addFromCloudflare': '从 Cloudflare 添加',
  'autoGetBestNodes': '自动获取最优节点',
  'manualAdd': '手动添加',
  'inputServerInfo': '输入服务器信息',
  'scanQrCode': '扫描二维码',
  'importFromQrCode': '从二维码导入配置',
  'importFromClipboard': '从剪贴板导入',
  'pasteServerConfig': '粘贴服务器配置',
  'diagnosticTool': '诊断工具',
  
  // 设置页面
  'generalSettings': '通用设置',
  'networkSettings': '网络设置',
  'about': '关于',
  'autoStart': '开机自启',
  'autoStartDesc': '系统启动时自动运行',
  'autoConnect': '自动连接',
  'autoConnectDesc': '启动应用时自动连接',
  'proxyMode': '代理模式',
  'globalProxy': '全局代理',
  'routeSettings': '路由设置',
  'configureRules': '配置分流规则',
  'currentVersion': '当前版本',
  'checkUpdate': '检查更新',
  'officialWebsite': '官方网站',
  'contactEmail': '联系邮箱',
  'privacyPolicy': '隐私政策',
  'clearCache': '清除缓存',
  'cacheCleared': '缓存已清除',
  'language': '语言',
  'theme': '主题',
  'systemTheme': '跟随系统',
  'lightTheme': '浅色',
  'darkTheme': '深色',
  
  // 消息
  'operationFailed': '操作失败',
  'testingLatency': '正在测试延迟...',
  'gettingNodes': '正在获取节点...',
  'alreadyLatestVersion': '已是最新版本',
  'serverAdded': '服务器已添加',
  'serverDeleted': '服务器已删除',
  
  // Cloudflare测试
  'startTest': '开始测试',
  'testing': '测试中',
  'testCompleted': '测试完成',
  'testFailed': '测试失败',
  'preparing': '正在准备...',
  
  // 新增的进度相关文本
  'preparingTestEnvironment': '准备测试环境',
  'initializing': '正在初始化',
  'generatingTestIPs': '生成测试IP',
  'samplingFromIPRanges': '从 %s 个IP段采样',
  'testingDelay': '测试延迟',
  'testingDownloadSpeed': '测试下载速度',
  'startingSpeedTest': '开始测速',
  'foundQualityNodes': '找到 %s 个优质节点',
  
  // 新增的测试相关文本
  'noQualifiedNodes': '未找到符合条件的节点',
  'checkNetworkOrRequirements': '请检查网络连接或降低筛选要求',
  'noServersMetSpeedRequirement': '没有服务器满足下载速度要求',
  'lowerSpeedRequirement': '请降低速度要求或检查网络',
  'nodeProgress': '%s/%s',
  'ipRanges': '%s 个IP段',
  
  // 诊断
  'runDiagnostics': '运行诊断',
  'fileCheck': '文件检查',
  'networkTest': '网络测试',
  'systemInfo': '系统信息',
  
  // 退出确认
  'confirmExit': '退出确认',
  'confirmExitDesc': '请选择操作：',
  'minimize': '最小化到托盘',
  'exitApp': '退出应用',
  
  // 新增的节点获取相关文本
  'gettingBestNodes': '正在获取最优节点...',
  'getNodesFailed': '获取节点失败，请重试',
  'noValidNodes': '无法获取有效节点',
  
  // 新增：连接断开相关文本
  'connectionLost': '连接已断开',
  'vpnDisconnected': 'VPN连接已断开',
};

// 英语翻译
const Map<String, String> _enTranslations = {
  'home': 'Home',
  'servers': 'Servers',
  'settings': 'Settings',
  'disconnect': 'Disconnect',
  'connected': 'Connected',
  'disconnected': 'Disconnected',
  'connecting': 'Connecting...',
  'disconnecting': 'Disconnecting...',
  'close': 'Close',
  'vpnDisconnected': 'VPN connection lost',
};

// 繁体中文
const Map<String, String> _zhTwTranslations = {
  'home': '首頁',
  'servers': '伺服器',
  'settings': '設定',
  'disconnect': '斷開',
  'connected': '已連線',
  'disconnected': '未連線',
  'connecting': '正在連線...',
  'disconnecting': '正在斷開...',
  'close': '關閉',
  'vpnDisconnected': 'VPN連線已斷開',
};

// 西班牙语
const Map<String, String> _esTranslations = {
  'home': 'Inicio',
  'servers': 'Servidores',
  'settings': 'Configuración',
  'disconnect': 'Desconectar',
  'connected': 'Conectado',
  'disconnected': 'Desconectado',
  'connecting': 'Conectando...',
  'disconnecting': 'Desconectando...',
  'close': 'Cerrar',
  'vpnDisconnected': 'Conexión VPN perdida',
};

// 俄语
const Map<String, String> _ruTranslations = {
  'home': 'Главная',
  'servers': 'Серверы',
  'settings': 'Настройки',
  'disconnect': 'Отключить',
  'connected': 'Подключено',
  'disconnected': 'Отключено',
  'connecting': 'Подключение...',
  'disconnecting': 'Отключение...',
  'close': 'Закрыть',
  'vpnDisconnected': 'VPN-соединение потеряно',
};

// 阿拉伯语
const Map<String, String> _arTranslations = {
  'home': 'الرئيسية',
  'servers': 'الخوادم',
  'settings': 'الإعدادات',
  'disconnect': 'قطع الاتصال',
  'connected': 'متصل',
  'disconnected': 'غير متصل',
  'connecting': 'جاري الاتصال...',
  'disconnecting': 'جاري قطع الاتصال...',
  'close': 'إغلاق',
  'vpnDisconnected': 'انقطع اتصال VPN',
};