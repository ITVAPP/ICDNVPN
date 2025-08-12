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
  String get cancel => _get('cancel');
  String get ok => _get('ok');
  String get unknownError => _get('unknownError');
  
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
  String get importFromClipboard => _get('importFromClipboard');
  String get pasteServerConfig => _get('pasteServerConfig');
  String get diagnosticTool => _get('diagnosticTool');
  String get diagnosticNotSupported => _get('diagnosticNotSupported');
  
  // 设置页面
  String get generalSettings => _get('generalSettings');
  String get about => _get('about');
  String get autoStart => _get('autoStart');
  String get autoStartDesc => _get('autoStartDesc');
  String get autoConnect => _get('autoConnect');
  String get autoConnectDesc => _get('autoConnectDesc');
  String get globalProxy => _get('globalProxy');
  String get globalProxyDesc => _get('globalProxyDesc');
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
  
  // 权限相关
  String get permissionRequired => _get('permissionRequired');
  String get permissionReason => _get('permissionReason');
  
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
  String get testingResponseSpeed => _get('testingResponseSpeed');
  String get startingTraceTest => _get('startingTraceTest');
  String get foundQualityNodes => _get('foundQualityNodes');
  
  // 新增的测试相关文本
  String get noQualifiedNodes => _get('noQualifiedNodes');
  String get checkNetworkOrRequirements => _get('checkNetworkOrRequirements');
  String get nodeProgress => _get('nodeProgress');
  String get ipRanges => _get('ipRanges');
  
  // 诊断
  String get runDiagnostics => _get('runDiagnostics');
  String get fileCheck => _get('fileCheck');
  String get networkTest => _get('networkTest');
  String get systemInfo => _get('systemInfo');
  String get size => _get('size');
  String get modified => _get('modified');
  String get config => _get('config');
  String get ipFile => _get('ipFile');
  String get missing => _get('missing');
  String get ipRangesCount => _get('ipRangesCount');
  String get sample => _get('sample');
  String get cloudflareTest => _get('cloudflareTest');
  String get os => _get('os');
  String get version => _get('version');
  String get failed => _get('failed');
  
  // 退出确认
  String get confirmExit => _get('confirmExit');
  String get confirmExitDesc => _get('confirmExitDesc');
  String get minimize => _get('minimize');
  String get exitApp => _get('exitApp');
  
  // 新增的节点获取相关文本
  String get gettingBestNodes => _get('gettingBestNodes');
  String get getNodesFailed => _get('getNodesFailed');
  String get noValidNodes => _get('noValidNodes');
  String get nodesAdded => _get('nodesAdded');
  
  // 连接断开相关文本
  String get connectionLost => _get('connectionLost');
  String get vpnDisconnected => _get('vpnDisconnected');
  
  // 版本更新相关
  String get importantUpdate => _get('importantUpdate');
  String get newVersionFound => _get('newVersionFound');
  String get versionLabel => _get('versionLabel');
  String get forceUpdateNotice => _get('forceUpdateNotice');
  String get updateContent => _get('updateContent');
  String get remindLater => _get('remindLater');
  String get updateNow => _get('updateNow');
  String get downloadFailed => _get('downloadFailed');
  String get downloadFailedMessage => _get('downloadFailedMessage');
  String get openBrowser => _get('openBrowser');
  String get goToAppStore => _get('goToAppStore');
  String get goToDownload => _get('goToDownload');
  String get pathCopied => _get('pathCopied');
  String get manualInstallNotice => _get('manualInstallNotice');
  String get copyPath => _get('copyPath');
  String get linkCopied => _get('linkCopied');
  
  // 广告相关
  String get adLabel => _get('adLabel');
  String get secondsToClose => _get('secondsToClose');
  String get tapToLearnMore => _get('tapToLearnMore');
  
  // V2Ray相关
  String get proxyServer => _get('proxyServer');
  String get v2rayRunning => _get('v2rayRunning');
  String get disconnectButton => _get('disconnectButton');
  
  // 新增的UI相关文本
  String get autoSelectBestNode => _get('autoSelectBestNode');
  String get getNodeFailedWithRetry => _get('getNodeFailedWithRetry');
  String get retry => _get('retry');
  String get switchNode => _get('switchNode');
  String get confirmSwitchNode => _get('confirmSwitchNode');
  String get switchNodeDesc => _get('switchNodeDesc');
  String get switching => _get('switching');
  String get switchingNode => _get('switchingNode');
  String get switchedToNode => _get('switchedToNode');
  String get switchFailed => _get('switchFailed');
  String get testingServers => _get('testingServers');
  String get serversUnit => _get('serversUnit');
  String get testCompletedWithCount => _get('testCompletedWithCount');
  String get updateFailed => _get('updateFailed');
  String get clearCacheConfirm => _get('clearCacheConfirm');
  String get tip => _get('tip');
  String get clearCacheDisconnectWarning => _get('clearCacheDisconnectWarning');
  String get continue_ => _get('continue');
  String get clearingCache => _get('clearingCache');
  String get cacheDetails => _get('cacheDetails');
  String get reGetNodes => _get('reGetNodes');
  String get newVersion => _get('newVersion');
  
  // 代理模式（新增）
  String get globalProxyMode => _get('globalProxyMode');
  String get smartProxyMode => _get('smartProxyMode');
  String get proxyOnlyMode => _get('proxyOnlyMode');
  
  // 通知栏（新增）
  String get notificationChannelName => _get('notificationChannelName');
  String get notificationChannelDesc => _get('notificationChannelDesc');
  String get trafficStats => _get('trafficStats');
  
  // 国家/地区名称
  String get countryChina => _get('countryChina');
  String get countryHongKong => _get('countryHongKong');
  String get countryTaiwan => _get('countryTaiwan');
  String get countrySingapore => _get('countrySingapore');
  String get countryJapan => _get('countryJapan');
  String get countrySouthKorea => _get('countrySouthKorea');
  String get countryThailand => _get('countryThailand');
  String get countryMalaysia => _get('countryMalaysia');
  String get countryPhilippines => _get('countryPhilippines');
  String get countryIndonesia => _get('countryIndonesia');
  String get countryIndia => _get('countryIndia');
  String get countryUAE => _get('countryUAE');
  String get countryVietnam => _get('countryVietnam');
  String get countryTurkey => _get('countryTurkey');
  String get countryIsrael => _get('countryIsrael');
  String get countryUSA => _get('countryUSA');
  String get countryCanada => _get('countryCanada');
  String get countryMexico => _get('countryMexico');
  String get countryUK => _get('countryUK');
  String get countryFrance => _get('countryFrance');
  String get countryGermany => _get('countryGermany');
  String get countryNetherlands => _get('countryNetherlands');
  String get countrySpain => _get('countrySpain');
  String get countryItaly => _get('countryItaly');
  String get countrySwitzerland => _get('countrySwitzerland');
  String get countryAustria => _get('countryAustria');
  String get countrySweden => _get('countrySweden');
  String get countryDenmark => _get('countryDenmark');
  String get countryPoland => _get('countryPoland');
  String get countryRussia => _get('countryRussia');
  String get countryBelgium => _get('countryBelgium');
  String get countryCzechia => _get('countryCzechia');
  String get countryFinland => _get('countryFinland');
  String get countryIreland => _get('countryIreland');
  String get countryNorway => _get('countryNorway');
  String get countryPortugal => _get('countryPortugal');
  String get countryGreece => _get('countryGreece');
  String get countryRomania => _get('countryRomania');
  String get countryUkraine => _get('countryUkraine');
  String get countryAustralia => _get('countryAustralia');
  String get countryNewZealand => _get('countryNewZealand');
  String get countryBrazil => _get('countryBrazil');
  String get countryArgentina => _get('countryArgentina');
  String get countryChile => _get('countryChile');
  String get countryPeru => _get('countryPeru');
  String get countryColombia => _get('countryColombia');
  String get countryVenezuela => _get('countryVenezuela');
  String get countryUruguay => _get('countryUruguay');
  String get countrySouthAfrica => _get('countrySouthAfrica');
  String get countryEgypt => _get('countryEgypt');
  String get countryNigeria => _get('countryNigeria');
  String get countryKenya => _get('countryKenya');
  String get countryMorocco => _get('countryMorocco');
  String get countryTunisia => _get('countryTunisia');
  String get countryEthiopia => _get('countryEthiopia');
  
  // 大洲名称
  String get continentAsia => _get('continentAsia');
  String get continentNorthAmerica => _get('continentNorthAmerica');
  String get continentEurope => _get('continentEurope');
  String get continentOceania => _get('continentOceania');
  String get continentSouthAmerica => _get('continentSouthAmerica');
  String get continentAfrica => _get('continentAfrica');
  String get continentUnknown => _get('continentUnknown');
  
  // 带参数的文本格式化方法
  String samplingFromRanges(int count) {
    final template = _get('samplingFromIPRanges');
    return template.replaceAll('%s', count.toString());
  }
  
  String foundNodes(int count) {
    final template = _get('foundQualityNodes');
    return template.replaceAll('%s', count.toString());
  }
  
  String secondsToCloseFormat(int seconds) {
    final template = _get('secondsToClose');
    return template.replaceAll('%s', seconds.toString());
  }
  
  String downloadFailedFormat(String error) {
    final template = _get('downloadFailedMessage');
    return template.replaceAll('%s', error);
  }
  
  String manualInstallFormat(String path) {
    final template = _get('manualInstallNotice');
    return template.replaceAll('%s', path);
  }
  
  String versionFormat(String version) {
    final template = _get('versionLabel');
    return template.replaceAll('%s', version);
  }
  
  String nodesAddedFormat(int count) {
    final template = _get('nodesAdded');
    return template.replaceAll('%s', count.toString());
  }
  
  // 新增的带参数方法
  String autoSelectedBestNode(String nodeName, int ping) {
    final template = _get('autoSelectBestNode');
    return template.replaceAll('%name', nodeName).replaceAll('%ping', ping.toString());
  }
  
  String switchToNodeConfirm(String nodeName) {
    final template = _get('confirmSwitchNode');
    return template.replaceAll('%s', nodeName);
  }
  
  String switchedTo(String nodeName) {
    final template = _get('switchedToNode');
    return template.replaceAll('%s', nodeName);
  }
  
  String switchFailedError(String error) {
    final template = _get('switchFailed');
    return template.replaceAll('%s', error);
  }
  
  String testingServersCount(int count) {
    final template = _get('testingServers');
    return template.replaceAll('%s', count.toString());
  }
  
  String testCompletedCount(int count) {
    final template = _get('testCompletedWithCount');
    return template.replaceAll('%s', count.toString());
  }
  
  String checkUpdateFailedError(String error) {
    final template = _get('updateFailed');
    return template.replaceAll('%s', error);
  }
  
  String newVersionFormat(String version) {
    final template = _get('newVersion');
    return template.replaceAll('%s', version);
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
  'cancel': '取消',
  'ok': '确定',
  'unknownError': '未知错误',
  
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
  'importFromClipboard': '从剪贴板导入',
  'pasteServerConfig': '粘贴服务器配置',
  'diagnosticTool': '诊断工具',
  'diagnosticNotSupported': '诊断工具暂不支持移动平台',
  
  // 设置页面
  'generalSettings': '通用设置',
  'about': '关于',
  'autoStart': '开机自启',
  'autoStartDesc': '系统启动时自动运行',
  'autoConnect': '自动连接',
  'autoConnectDesc': '启动应用时自动连接',
  'globalProxy': '全局代理',
  'globalProxyDesc': '开启后所有流量都通过代理，关闭后智能分流',
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
  
  // 权限相关
  'permissionRequired': 'VPN权限',
  'permissionReason': '需要VPN权限才能建立安全连接',
  
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
  'testingResponseSpeed': '测试响应速度',
  'startingTraceTest': '开始响应速度测试',
  'foundQualityNodes': '找到 %s 个优质节点',
  
  // 新增的测试相关文本
  'noQualifiedNodes': '未找到符合条件的节点',
  'checkNetworkOrRequirements': '请检查网络连接或降低筛选要求',
  'nodeProgress': '%s/%s',
  'ipRanges': '%s 个IP段',
  
  // 诊断
  'runDiagnostics': '运行诊断',
  'fileCheck': '文件检查',
  'networkTest': '网络测试',
  'systemInfo': '系统信息',
  'size': '大小',
  'modified': '修改时间',
  'config': '配置',
  'ipFile': 'IP文件',
  'missing': '缺失',
  'ipRangesCount': 'IP段数量',
  'sample': '示例',
  'cloudflareTest': 'Cloudflare测试',
  'os': '操作系统',
  'version': '版本',
  'failed': '失败',
  
  // 退出确认
  'confirmExit': '退出确认',
  'confirmExitDesc': '请选择操作：',
  'minimize': '最小化到托盘',
  'exitApp': '退出应用',
  
  // 新增的节点获取相关文本
  'gettingBestNodes': '正在获取最优节点...',
  'getNodesFailed': '获取节点失败，请重试',
  'noValidNodes': '无法获取有效节点',
  'nodesAdded': '已添加 %s 个服务器',
  
  // 连接断开相关文本
  'connectionLost': '连接已断开',
  'vpnDisconnected': 'VPN连接已断开',
  
  // 版本更新相关
  'importantUpdate': '重要更新',
  'newVersionFound': '发现新版本',
  'versionLabel': '版本 %s',
  'forceUpdateNotice': '此版本包含重要更新，需要立即升级',
  'updateContent': '更新内容：',
  'remindLater': '稍后提醒',
  'updateNow': '立即更新',
  'downloadFailed': '下载失败',
  'downloadFailedMessage': '下载失败: %s\n\n是否打开浏览器下载？',
  'openBrowser': '打开浏览器',
  'goToAppStore': '前往App Store',
  'goToDownload': '前往下载',
  'pathCopied': '路径已复制到剪贴板',
  'manualInstallNotice': '请手动安装APK文件：\n%s',
  'copyPath': '复制路径',
  'linkCopied': '下载链接已复制到剪贴板',
  
  // 广告相关
  'adLabel': 'AD',
  'secondsToClose': '%s秒后自动关闭',
  'tapToLearnMore': '点击了解详情',
  
  // V2Ray相关
  'proxyServer': '代理服务器',
  'v2rayRunning': 'V2Ray运行中',
  'disconnectButton': '断开',
  
  // 新增的UI相关文本
  'autoSelectBestNode': '已自动选择最优节点: %name (%ping ms)',
  'getNodeFailedWithRetry': '获取节点失败，请检查网络连接后重试',
  'retry': '重试',
  'switchNode': '切换节点',
  'confirmSwitchNode': '是否切换到 %s？',
  'switchNodeDesc': '当前连接将会断开并重新连接。',
  'switching': '切换',
  'switchingNode': '正在切换节点...',
  'switchedToNode': '已切换到 %s',
  'switchFailed': '切换失败: %s',
  'testingServers': '测试中 %s 个服务器...',
  'serversUnit': '个服务器',
  'testCompletedWithCount': '测试完成，已更新 %s 个服务器',
  'updateFailed': '检查更新失败: %s',
  'clearCacheConfirm': '将清除所有缓存数据，包括服务器列表、设置等。确定要继续吗？',
  'tip': '提示',
  'clearCacheDisconnectWarning': '清除缓存将断开当前VPN连接，是否继续？',
  'continue': '继续',
  'clearingCache': '正在清除缓存...',
  'cacheDetails': '已清除：日志文件、服务器列表、用户设置',
  'reGetNodes': '重新获取节点',
  'newVersion': '新版 %s',
  
  // 代理模式（新增）
  'globalProxyMode': '全局代理模式',
  'smartProxyMode': '智能代理模式',
  'proxyOnlyMode': '仅代理模式',
  
  // 通知栏（新增）
  'notificationChannelName': 'VPN服务',
  'notificationChannelDesc': 'VPN连接状态通知',
  'trafficStats': '流量: ↑%upload ↓%download',
  
  // 国家/地区名称
  'countryChina': '中国',
  'countryHongKong': '香港',
  'countryTaiwan': '台湾',
  'countrySingapore': '新加坡',
  'countryJapan': '日本',
  'countrySouthKorea': '韩国',
  'countryThailand': '泰国',
  'countryMalaysia': '马来西亚',
  'countryPhilippines': '菲律宾',
  'countryIndonesia': '印度尼西亚',
  'countryIndia': '印度',
  'countryUAE': '阿联酋',
  'countryVietnam': '越南',
  'countryTurkey': '土耳其',
  'countryIsrael': '以色列',
  'countryUSA': '美国',
  'countryCanada': '加拿大',
  'countryMexico': '墨西哥',
  'countryUK': '英国',
  'countryFrance': '法国',
  'countryGermany': '德国',
  'countryNetherlands': '荷兰',
  'countrySpain': '西班牙',
  'countryItaly': '意大利',
  'countrySwitzerland': '瑞士',
  'countryAustria': '奥地利',
  'countrySweden': '瑞典',
  'countryDenmark': '丹麦',
  'countryPoland': '波兰',
  'countryRussia': '俄罗斯',
  'countryBelgium': '比利时',
  'countryCzechia': '捷克',
  'countryFinland': '芬兰',
  'countryIreland': '爱尔兰',
  'countryNorway': '挪威',
  'countryPortugal': '葡萄牙',
  'countryGreece': '希腊',
  'countryRomania': '罗马尼亚',
  'countryUkraine': '乌克兰',
  'countryAustralia': '澳大利亚',
  'countryNewZealand': '新西兰',
  'countryBrazil': '巴西',
  'countryArgentina': '阿根廷',
  'countryChile': '智利',
  'countryPeru': '秘鲁',
  'countryColombia': '哥伦比亚',
  'countryVenezuela': '委内瑞拉',
  'countryUruguay': '乌拉圭',
  'countrySouthAfrica': '南非',
  'countryEgypt': '埃及',
  'countryNigeria': '尼日利亚',
  'countryKenya': '肯尼亚',
  'countryMorocco': '摩洛哥',
  'countryTunisia': '突尼斯',
  'countryEthiopia': '埃塞俄比亚',
  
  // 大洲名称
  'continentAsia': '亚洲',
  'continentNorthAmerica': '北美洲',
  'continentEurope': '欧洲',
  'continentOceania': '大洋洲',
  'continentSouthAmerica': '南美洲',
  'continentAfrica': '非洲',
  'continentUnknown': '未知',
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
  'cancel': 'Cancel',
  'ok': 'OK',
  'unknownError': 'Unknown Error',
  
  'clickToConnect': 'Click to Connect',
  'clickToDisconnect': 'Click to Disconnect',
  'currentServer': 'Current Server',
  'selectServer': 'Select Server',
  'upload': 'Upload',
  'download': 'Download',
  'autoSelectNode': 'Auto Select',
  'speedTest': 'Speed Test',
  'refresh': 'Refresh',
  'noNodesHint': 'No nodes, please get first',
  
  'serverList': 'Server List',
  'addServer': 'Add Server',
  'deleteServer': 'Delete Server',
  'testLatency': 'Test Latency',
  'sortAscending': 'Sort by Latency (Low to High)',
  'sortDescending': 'Sort by Latency (High to Low)',
  'fromCloudflare': 'From Cloudflare',
  'noServers': 'No Servers',
  'confirmDelete': 'Confirm Delete',
  'latency': 'Latency',
  
  'addFromCloudflare': 'Add from Cloudflare',
  'autoGetBestNodes': 'Auto get best nodes',
  'manualAdd': 'Manual Add',
  'inputServerInfo': 'Input server info',
  'importFromClipboard': 'Import from Clipboard',
  'pasteServerConfig': 'Paste server config',
  'diagnosticTool': 'Diagnostic Tool',
  'diagnosticNotSupported': 'Diagnostic tool is not supported on mobile platforms',
  
  'generalSettings': 'General Settings',
  'about': 'About',
  'autoStart': 'Auto Start',
  'autoStartDesc': 'Start automatically when system boots',
  'autoConnect': 'Auto Connect',
  'autoConnectDesc': 'Connect automatically when app starts',
  'globalProxy': 'Global Proxy',
  'globalProxyDesc': 'When enabled, all traffic goes through proxy. When disabled, smart routing is used',
  'currentVersion': 'Current Version',
  'checkUpdate': 'Check Update',
  'officialWebsite': 'Official Website',
  'contactEmail': 'Contact Email',
  'privacyPolicy': 'Privacy Policy',
  'clearCache': 'Clear Cache',
  'cacheCleared': 'Cache Cleared',
  'language': 'Language',
  'theme': 'Theme',
  'systemTheme': 'System',
  'lightTheme': 'Light',
  'darkTheme': 'Dark',
  
  // 权限相关
  'permissionRequired': 'VPN Permission',
  'permissionReason': 'VPN permission is required to establish a secure connection',
  
  'operationFailed': 'Operation Failed',
  'testingLatency': 'Testing Latency...',
  'gettingNodes': 'Getting Nodes...',
  'alreadyLatestVersion': 'Already Latest Version',
  'serverAdded': 'Server Added',
  'serverDeleted': 'Server Deleted',
  
  'startTest': 'Start Test',
  'testing': 'Testing',
  'testCompleted': 'Test Completed',
  'testFailed': 'Test Failed',
  'preparing': 'Preparing...',
  
  'preparingTestEnvironment': 'Preparing test environment',
  'initializing': 'Initializing',
  'generatingTestIPs': 'Generating test IPs',
  'samplingFromIPRanges': 'Sampling from %s IP ranges',
  'testingDelay': 'Testing delay',
  'testingResponseSpeed': 'Testing response speed',
  'startingTraceTest': 'Starting response speed test',
  'foundQualityNodes': 'Found %s quality nodes',
  
  'noQualifiedNodes': 'No qualified nodes found',
  'checkNetworkOrRequirements': 'Please check network connection or lower requirements',
  'nodeProgress': '%s/%s',
  'ipRanges': '%s IP ranges',
  
  'runDiagnostics': 'Run Diagnostics',
  'fileCheck': 'File Check',
  'networkTest': 'Network Test',
  'systemInfo': 'System Info',
  'size': 'Size',
  'modified': 'Modified',
  'config': 'Config',
  'ipFile': 'IP File',
  'missing': 'Missing',
  'ipRangesCount': 'IP Ranges Count',
  'sample': 'Sample',
  'cloudflareTest': 'Cloudflare Test',
  'os': 'OS',
  'version': 'Version',
  'failed': 'Failed',
  
  'confirmExit': 'Confirm Exit',
  'confirmExitDesc': 'Please choose an action:',
  'minimize': 'Minimize to Tray',
  'exitApp': 'Exit App',
  
  'gettingBestNodes': 'Getting best nodes...',
  'getNodesFailed': 'Failed to get nodes, please retry',
  'noValidNodes': 'No valid nodes found',
  'nodesAdded': 'Added %s servers',
  
  'connectionLost': 'Connection Lost',
  'vpnDisconnected': 'VPN Disconnected',
  
  'importantUpdate': 'Important Update',
  'newVersionFound': 'New Version Found',
  'versionLabel': 'Version %s',
  'forceUpdateNotice': 'This version contains important updates and requires immediate upgrade',
  'updateContent': 'Update Content:',
  'remindLater': 'Remind Later',
  'updateNow': 'Update Now',
  'downloadFailed': 'Download Failed',
  'downloadFailedMessage': 'Download failed: %s\n\nOpen browser to download?',
  'openBrowser': 'Open Browser',
  'goToAppStore': 'Go to App Store',
  'goToDownload': 'Go to Download',
  'pathCopied': 'Path copied to clipboard',
  'manualInstallNotice': 'Please manually install APK file:\n%s',
  'copyPath': 'Copy Path',
  'linkCopied': 'Download link copied to clipboard',
  
  'adLabel': 'AD',
  'secondsToClose': 'Close in %s seconds',
  'tapToLearnMore': 'Tap to learn more',
  
  'proxyServer': 'Proxy Server',
  'v2rayRunning': 'V2Ray Running',
  'disconnectButton': 'Disconnect',
  
  'autoSelectBestNode': 'Auto selected best node: %name (%ping ms)',
  'getNodeFailedWithRetry': 'Failed to get nodes, please check network and retry',
  'retry': 'Retry',
  'switchNode': 'Switch Node',
  'confirmSwitchNode': 'Switch to %s?',
  'switchNodeDesc': 'Current connection will be disconnected and reconnected.',
  'switching': 'Switching',
  'switchingNode': 'Switching node...',
  'switchedToNode': 'Switched to %s',
  'switchFailed': 'Switch failed: %s',
  'testingServers': 'Testing %s servers...',
  'serversUnit': 'servers',
  'testCompletedWithCount': 'Test completed, updated %s servers',
  'updateFailed': 'Check update failed: %s',
  'clearCacheConfirm': 'All cache data will be cleared, including server list and settings. Continue?',
  'tip': 'Tip',
  'clearCacheDisconnectWarning': 'Clearing cache will disconnect current VPN connection. Continue?',
  'continue': 'Continue',
  'clearingCache': 'Clearing cache...',
  'cacheDetails': 'Cleared: Log files, server list, user settings',
  'reGetNodes': 'Re-get Nodes',
  'newVersion': 'New %s',
  
  // 代理模式（新增）
  'globalProxyMode': 'Global Proxy',
  'smartProxyMode': 'Smart Proxy',
  'proxyOnlyMode': 'Proxy Only',
  
  // 通知栏（新增）
  'notificationChannelName': 'VPN Service',
  'notificationChannelDesc': 'VPN connection status notification',
  'trafficStats': 'Traffic: ↑%upload ↓%download',
  
  // 国家/地区名称 (英文)
  'countryChina': 'China',
  'countryHongKong': 'Hong Kong',
  'countryTaiwan': 'Taiwan',
  'countrySingapore': 'Singapore',
  'countryJapan': 'Japan',
  'countrySouthKorea': 'South Korea',
  'countryThailand': 'Thailand',
  'countryMalaysia': 'Malaysia',
  'countryPhilippines': 'Philippines',
  'countryIndonesia': 'Indonesia',
  'countryIndia': 'India',
  'countryUAE': 'UAE',
  'countryVietnam': 'Vietnam',
  'countryTurkey': 'Turkey',
  'countryIsrael': 'Israel',
  'countryUSA': 'USA',
  'countryCanada': 'Canada',
  'countryMexico': 'Mexico',
  'countryUK': 'UK',
  'countryFrance': 'France',
  'countryGermany': 'Germany',
  'countryNetherlands': 'Netherlands',
  'countrySpain': 'Spain',
  'countryItaly': 'Italy',
  'countrySwitzerland': 'Switzerland',
  'countryAustria': 'Austria',
  'countrySweden': 'Sweden',
  'countryDenmark': 'Denmark',
  'countryPoland': 'Poland',
  'countryRussia': 'Russia',
  'countryBelgium': 'Belgium',
  'countryCzechia': 'Czechia',
  'countryFinland': 'Finland',
  'countryIreland': 'Ireland',
  'countryNorway': 'Norway',
  'countryPortugal': 'Portugal',
  'countryGreece': 'Greece',
  'countryRomania': 'Romania',
  'countryUkraine': 'Ukraine',
  'countryAustralia': 'Australia',
  'countryNewZealand': 'New Zealand',
  'countryBrazil': 'Brazil',
  'countryArgentina': 'Argentina',
  'countryChile': 'Chile',
  'countryPeru': 'Peru',
  'countryColombia': 'Colombia',
  'countryVenezuela': 'Venezuela',
  'countryUruguay': 'Uruguay',
  'countrySouthAfrica': 'South Africa',
  'countryEgypt': 'Egypt',
  'countryNigeria': 'Nigeria',
  'countryKenya': 'Kenya',
  'countryMorocco': 'Morocco',
  'countryTunisia': 'Tunisia',
  'countryEthiopia': 'Ethiopia',
  
  // 大洲名称 (英文)
  'continentAsia': 'Asia',
  'continentNorthAmerica': 'North America',
  'continentEurope': 'Europe',
  'continentOceania': 'Oceania',
  'continentSouthAmerica': 'South America',
  'continentAfrica': 'Africa',
  'continentUnknown': 'Unknown',
};

// 繁体中文
const Map<String, String> _zhTwTranslations = {
  'home': '首頁',
  'diagnosticNotSupported': '診斷工具暫不支持移動平台',
  'globalProxy': '全局代理',
  'globalProxyDesc': '開啟後所有流量都通過代理，關閉後智能分流',
  'permissionRequired': 'VPN權限',
  'permissionReason': '需要VPN權限才能建立安全連接',
  
  // 代理模式（新增）
  'globalProxyMode': '全局代理模式',
  'smartProxyMode': '智能代理模式',
  'proxyOnlyMode': '僅代理模式',
  
  // 通知栏（新增）
  'notificationChannelName': 'VPN服務',
  'notificationChannelDesc': 'VPN連接狀態通知',
  'trafficStats': '流量: ↑%upload ↓%download',
  // 其他繁体中文翻译待完善
};

// 西班牙语
const Map<String, String> _esTranslations = {
  'home': 'Inicio',
  'diagnosticNotSupported': 'La herramienta de diagnóstico no es compatible con plataformas móviles',
  'globalProxy': 'Proxy Global',
  'globalProxyDesc': 'Cuando está habilitado, todo el tráfico pasa por el proxy. Cuando está deshabilitado, se usa el enrutamiento inteligente',
  'permissionRequired': 'Permiso VPN',
  'permissionReason': 'Se requiere permiso VPN para establecer una conexión segura',
  
  // 代理模式（新增）
  'globalProxyMode': 'Proxy Global',
  'smartProxyMode': 'Proxy Inteligente',
  'proxyOnlyMode': 'Solo Proxy',
  
  // 通知栏（新增）
  'notificationChannelName': 'Servicio VPN',
  'notificationChannelDesc': 'Notificación de estado de conexión VPN',
  'trafficStats': 'Tráfico: ↑%upload ↓%download',
  // 其他西班牙语翻译待完善
};

// 俄语
const Map<String, String> _ruTranslations = {
  'home': 'Главная',
  'diagnosticNotSupported': 'Инструмент диагностики не поддерживается на мобильных платформах',
  'globalProxy': 'Глобальный прокси',
  'globalProxyDesc': 'При включении весь трафик проходит через прокси. При отключении используется умная маршрутизация',
  'permissionRequired': 'Разрешение VPN',
  'permissionReason': 'Для установления безопасного соединения требуется разрешение VPN',
  
  // 代理模式（新增）
  'globalProxyMode': 'Глобальный прокси',
  'smartProxyMode': 'Умный прокси',
  'proxyOnlyMode': 'Только прокси',
  
  // 通知栏（新增）
  'notificationChannelName': 'VPN сервис',
  'notificationChannelDesc': 'Уведомление о состоянии VPN-соединения',
  'trafficStats': 'Трафик: ↑%upload ↓%download',
  // 其他俄语翻译待完善
};

// 阿拉伯语
const Map<String, String> _arTranslations = {
  'home': 'الرئيسية',
  'diagnosticNotSupported': 'أداة التشخيص غير مدعومة على الأنظمة الأساسية للجوال',
  'globalProxy': 'وكيل عالمي',
  'globalProxyDesc': 'عند التمكين، تمر جميع حركة المرور عبر الوكيل. عند التعطيل، يتم استخدام التوجيه الذكي',
  'permissionRequired': 'إذن VPN',
  'permissionReason': 'مطلوب إذن VPN لإنشاء اتصال آمن',
  
  // 代理模式（新增）
  'globalProxyMode': 'وضع الوكيل العالمي',
  'smartProxyMode': 'وضع الوكيل الذكي',
  'proxyOnlyMode': 'وضع الوكيل فقط',
  
  // 通知栏（新增）
  'notificationChannelName': 'خدمة VPN',
  'notificationChannelDesc': 'إشعار حالة اتصال VPN',
  'trafficStats': 'حركة المرور: ↑%upload ↓%download',
  // 其他阿拉伯语翻译待完善
};