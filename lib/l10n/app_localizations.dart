import 'package:flutter/material.dart';

// 本地化基础类
abstract class AppLocalizations {
  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();
  
  static const List<Locale> supportedLocales = [
    Locale('en', 'US'),
    Locale('zh', 'CN'),
    Locale('zh', 'TW'),
    Locale('es', 'ES'),
    Locale('ru', 'RU'),
    Locale('ar', 'SA'),
  ];

  // 通用
  String get appName;
  String get home;
  String get servers;
  String get settings;
  String get connect;
  String get disconnect;
  String get connected;
  String get disconnected;
  String get connecting;
  String get disconnecting;
  
  // 主页
  String get clickToConnect;
  String get clickToDisconnect;
  String get currentServer;
  String get selectServer;
  String get upload;
  String get download;
  String get autoSelectNode;
  String get speedTest;
  String get refresh;
  String get protected;
  String get unprotected;
  
  // 服务器页面
  String get serverList;
  String get addServer;
  String get deleteServer;
  String get testLatency;
  String get sortAscending;
  String get sortDescending;
  String get fromCloudflare;
  String get resetServerList;
  String get noServers;
  String get confirmDelete;
  String get confirmReset;
  String get latency;
  String get location;
  String get cfNode;
  
  // 添加服务器
  String get addFromCloudflare;
  String get autoGetBestNodes;
  String get manualAdd;
  String get inputServerInfo;
  String get scanQrCode;
  String get importFromQrCode;
  String get importFromClipboard;
  String get pasteServerConfig;
  String get diagnosticTool;
  
  // 设置页面
  String get generalSettings;
  String get networkSettings;
  String get about;
  String get autoStart;
  String get autoStartDesc;
  String get autoConnect;
  String get autoConnectDesc;
  String get tunMode;
  String get tunModeDesc;
  String get proxyMode;
  String get globalProxy;
  String get routeSettings;
  String get configureRules;
  String get currentVersion;
  String get checkUpdate;
  String get officialWebsite;
  String get contactEmail;
  String get privacyPolicy;
  String get clearCache;
  String get cacheCleared;
  String get language;
  String get theme;
  String get systemTheme;
  String get lightTheme;
  String get darkTheme;
  
  // 消息
  String get operationFailed;
  String get testingLatency;
  String get gettingNodes;
  String get noAvailableServer;
  String get alreadyLatestVersion;
  String get serverAdded;
  String get serverDeleted;
  String get allServersDeleted;
  
  // Cloudflare测试
  String get nodeCount;
  String get maxLatency;
  String get minSpeed;
  String get testSamples;
  String get startTest;
  String get testing;
  String get testCompleted;
  String get testFailed;
  String get preparing;
  String get connectingNodes;
  String get processingResults;
  
  // 诊断
  String get runDiagnostics;
  String get diagnosticResults;
  String get fileCheck;
  String get networkTest;
  String get systemInfo;
  
  // 退出确认
  String get confirmExit;
  String get confirmExitDesc;
  String get minimize;
  String get exitApp;
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
    // 根据语言代码加载对应的本地化实现
    switch (locale.languageCode) {
      case 'zh':
        if (locale.countryCode == 'TW') {
          return AppLocalizationsZhTw();
        }
        return AppLocalizationsZhCn();
      case 'es':
        return AppLocalizationsEs();
      case 'ru':
        return AppLocalizationsRu();
      case 'ar':
        return AppLocalizationsAr();
      case 'en':
      default:
        return AppLocalizationsEn();
    }
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) => false;
}

// 英语
class AppLocalizationsEn extends AppLocalizations {
  // 通用
  @override String get appName => 'CFVPN';
  @override String get home => 'Home';
  @override String get servers => 'Servers';
  @override String get settings => 'Settings';
  @override String get connect => 'Connect';
  @override String get disconnect => 'Disconnect';
  @override String get connected => 'Connected';
  @override String get disconnected => 'Disconnected';
  @override String get connecting => 'Connecting...';
  @override String get disconnecting => 'Disconnecting...';
  
  // 主页
  @override String get clickToConnect => 'Click to Connect';
  @override String get clickToDisconnect => 'Click to Disconnect';
  @override String get currentServer => 'Current Server';
  @override String get selectServer => 'Select Server';
  @override String get upload => 'Upload';
  @override String get download => 'Download';
  @override String get autoSelectNode => 'Auto Select';
  @override String get speedTest => 'Speed Test';
  @override String get refresh => 'Refresh';
  @override String get protected => 'Protected';
  @override String get unprotected => 'Unprotected';
  
  // 服务器页面
  @override String get serverList => 'Server List';
  @override String get addServer => 'Add Server';
  @override String get deleteServer => 'Delete Server';
  @override String get testLatency => 'Test Latency';
  @override String get sortAscending => 'Sort: Low to High';
  @override String get sortDescending => 'Sort: High to Low';
  @override String get fromCloudflare => 'From Cloudflare';
  @override String get resetServerList => 'Reset Server List';
  @override String get noServers => 'No Servers';
  @override String get confirmDelete => 'Confirm Delete';
  @override String get confirmReset => 'This will clear all servers and re-fetch from Cloudflare. Continue?';
  @override String get latency => 'Latency';
  @override String get location => 'Location';
  @override String get cfNode => 'CF Node';
  
  // 添加服务器
  @override String get addFromCloudflare => 'Add from Cloudflare';
  @override String get autoGetBestNodes => 'Auto get best nodes';
  @override String get manualAdd => 'Manual Add';
  @override String get inputServerInfo => 'Input server information';
  @override String get scanQrCode => 'Scan QR Code';
  @override String get importFromQrCode => 'Import from QR code';
  @override String get importFromClipboard => 'Import from Clipboard';
  @override String get pasteServerConfig => 'Paste server configuration';
  @override String get diagnosticTool => 'Diagnostic Tool';
  
  // 设置页面
  @override String get generalSettings => 'General Settings';
  @override String get networkSettings => 'Network Settings';
  @override String get about => 'About';
  @override String get autoStart => 'Auto Start';
  @override String get autoStartDesc => 'Launch on system startup';
  @override String get autoConnect => 'Auto Connect';
  @override String get autoConnectDesc => 'Connect when app starts';
  @override String get tunMode => 'TUN Mode';
  @override String get tunModeDesc => 'Use TUN for global proxy';
  @override String get proxyMode => 'Proxy Mode';
  @override String get globalProxy => 'Global Proxy';
  @override String get routeSettings => 'Route Settings';
  @override String get configureRules => 'Configure routing rules';
  @override String get currentVersion => 'Current Version';
  @override String get checkUpdate => 'Check Update';
  @override String get officialWebsite => 'Official Website';
  @override String get contactEmail => 'Contact Email';
  @override String get privacyPolicy => 'Privacy Policy';
  @override String get clearCache => 'Clear Cache';
  @override String get cacheCleared => 'Cache Cleared';
  @override String get language => 'Language';
  @override String get theme => 'Theme';
  @override String get systemTheme => 'System';
  @override String get lightTheme => 'Light';
  @override String get darkTheme => 'Dark';
  
  // 消息
  @override String get operationFailed => 'Operation Failed';
  @override String get testingLatency => 'Testing Latency...';
  @override String get gettingNodes => 'Getting Nodes...';
  @override String get noAvailableServer => 'No Available Server';
  @override String get alreadyLatestVersion => 'Already Latest Version';
  @override String get serverAdded => 'Server Added';
  @override String get serverDeleted => 'Server Deleted';
  @override String get allServersDeleted => 'All Servers Deleted';
  
  // Cloudflare测试
  @override String get nodeCount => 'Node Count';
  @override String get maxLatency => 'Max Latency';
  @override String get minSpeed => 'Min Speed';
  @override String get testSamples => 'Test Samples';
  @override String get startTest => 'Start Test';
  @override String get testing => 'Testing';
  @override String get testCompleted => 'Test Completed';
  @override String get testFailed => 'Test Failed';
  @override String get preparing => 'Preparing...';
  @override String get connectingNodes => 'Connecting to nodes...';
  @override String get processingResults => 'Processing results...';
  
  // 诊断
  @override String get runDiagnostics => 'Run Diagnostics';
  @override String get diagnosticResults => 'Diagnostic Results';
  @override String get fileCheck => 'File Check';
  @override String get networkTest => 'Network Test';
  @override String get systemInfo => 'System Info';
  
  // 退出确认
  @override String get confirmExit => 'Exit Confirmation';
  @override String get confirmExitDesc => 'Choose an action:';
  @override String get minimize => 'Minimize to Tray';
  @override String get exitApp => 'Exit Application';
}

// 简体中文
class AppLocalizationsZhCn extends AppLocalizations {
  // 通用
  @override String get appName => 'CFVPN';
  @override String get home => '首页';
  @override String get servers => '服务器';
  @override String get settings => '设置';
  @override String get connect => '连接';
  @override String get disconnect => '断开';
  @override String get connected => '已连接';
  @override String get disconnected => '未连接';
  @override String get connecting => '正在连接...';
  @override String get disconnecting => '正在断开...';
  
  // 主页
  @override String get clickToConnect => '点击连接';
  @override String get clickToDisconnect => '点击断开';
  @override String get currentServer => '当前服务器';
  @override String get selectServer => '选择服务器';
  @override String get upload => '上传';
  @override String get download => '下载';
  @override String get autoSelectNode => '优选节点';
  @override String get speedTest => '测速';
  @override String get refresh => '刷新';
  @override String get protected => '已保护';
  @override String get unprotected => '未保护';
  
  // 服务器页面
  @override String get serverList => '服务器列表';
  @override String get addServer => '添加服务器';
  @override String get deleteServer => '删除服务器';
  @override String get testLatency => '测试延迟';
  @override String get sortAscending => '延迟从低到高';
  @override String get sortDescending => '延迟从高到低';
  @override String get fromCloudflare => '从Cloudflare添加';
  @override String get resetServerList => '重置服务器列表';
  @override String get noServers => '暂无服务器';
  @override String get confirmDelete => '确认删除';
  @override String get confirmReset => '这将清空所有服务器并重新从Cloudflare获取，确定继续吗？';
  @override String get latency => '延迟';
  @override String get location => '位置';
  @override String get cfNode => 'CF节点';
  
  // 添加服务器
  @override String get addFromCloudflare => '从 Cloudflare 添加';
  @override String get autoGetBestNodes => '自动获取最优节点';
  @override String get manualAdd => '手动添加';
  @override String get inputServerInfo => '输入服务器信息';
  @override String get scanQrCode => '扫描二维码';
  @override String get importFromQrCode => '从二维码导入配置';
  @override String get importFromClipboard => '从剪贴板导入';
  @override String get pasteServerConfig => '粘贴服务器配置';
  @override String get diagnosticTool => '诊断工具';
  
  // 设置页面
  @override String get generalSettings => '通用设置';
  @override String get networkSettings => '网络设置';
  @override String get about => '关于';
  @override String get autoStart => '开机自启';
  @override String get autoStartDesc => '系统启动时自动运行';
  @override String get autoConnect => '自动连接';
  @override String get autoConnectDesc => '启动应用时自动连接';
  @override String get tunMode => 'TUN 模式';
  @override String get tunModeDesc => '使用 TUN 虚拟网卡实现全局代理';
  @override String get proxyMode => '代理模式';
  @override String get globalProxy => '全局代理';
  @override String get routeSettings => '路由设置';
  @override String get configureRules => '配置分流规则';
  @override String get currentVersion => '当前版本';
  @override String get checkUpdate => '检查更新';
  @override String get officialWebsite => '官方网站';
  @override String get contactEmail => '联系邮箱';
  @override String get privacyPolicy => '隐私政策';
  @override String get clearCache => '清除缓存';
  @override String get cacheCleared => '缓存已清除';
  @override String get language => '语言';
  @override String get theme => '主题';
  @override String get systemTheme => '跟随系统';
  @override String get lightTheme => '浅色';
  @override String get darkTheme => '深色';
  
  // 消息
  @override String get operationFailed => '操作失败';
  @override String get testingLatency => '正在测试延迟...';
  @override String get gettingNodes => '正在获取节点...';
  @override String get noAvailableServer => '没有可用的服务器';
  @override String get alreadyLatestVersion => '已是最新版本';
  @override String get serverAdded => '服务器已添加';
  @override String get serverDeleted => '服务器已删除';
  @override String get allServersDeleted => '所有服务器已删除';
  
  // Cloudflare测试
  @override String get nodeCount => '添加数量';
  @override String get maxLatency => '延迟上限';
  @override String get minSpeed => '最低网速';
  @override String get testSamples => '测试样本数';
  @override String get startTest => '开始测试';
  @override String get testing => '测试中';
  @override String get testCompleted => '测试完成';
  @override String get testFailed => '测试失败';
  @override String get preparing => '正在准备...';
  @override String get connectingNodes => '正在连接节点...';
  @override String get processingResults => '正在处理结果...';
  
  // 诊断
  @override String get runDiagnostics => '运行诊断';
  @override String get diagnosticResults => '诊断结果';
  @override String get fileCheck => '文件检查';
  @override String get networkTest => '网络测试';
  @override String get systemInfo => '系统信息';
  
  // 退出确认
  @override String get confirmExit => '退出确认';
  @override String get confirmExitDesc => '请选择操作：';
  @override String get minimize => '最小化到托盘';
  @override String get exitApp => '退出应用';
}

// 繁体中文
class AppLocalizationsZhTw extends AppLocalizations {
  // 通用
  @override String get appName => 'CFVPN';
  @override String get home => '首頁';
  @override String get servers => '伺服器';
  @override String get settings => '設定';
  @override String get connect => '連接';
  @override String get disconnect => '斷開';
  @override String get connected => '已連接';
  @override String get disconnected => '未連接';
  @override String get connecting => '正在連接...';
  @override String get disconnecting => '正在斷開...';
  
  // 主页
  @override String get clickToConnect => '點擊連接';
  @override String get clickToDisconnect => '點擊斷開';
  @override String get currentServer => '當前伺服器';
  @override String get selectServer => '選擇伺服器';
  @override String get upload => '上傳';
  @override String get download => '下載';
  @override String get autoSelectNode => '優選節點';
  @override String get speedTest => '測速';
  @override String get refresh => '重新整理';
  @override String get protected => '已保護';
  @override String get unprotected => '未保護';
  
  // 其他省略...实际应该包含所有字段的繁体中文翻译
  // 这里只展示部分作为示例
  @override String get serverList => '伺服器列表';
  @override String get addServer => '新增伺服器';
  @override String get deleteServer => '刪除伺服器';
  @override String get testLatency => '測試延遲';
  @override String get sortAscending => '延遲從低到高';
  @override String get sortDescending => '延遲從高到低';
  @override String get fromCloudflare => '從Cloudflare新增';
  @override String get resetServerList => '重置伺服器列表';
  @override String get noServers => '暫無伺服器';
  @override String get confirmDelete => '確認刪除';
  @override String get confirmReset => '這將清空所有伺服器並重新從Cloudflare獲取，確定繼續嗎？';
  @override String get latency => '延遲';
  @override String get location => '位置';
  @override String get cfNode => 'CF節點';
  
  // 为了节省空间，其他字段使用与简体中文相同的实现
  // 实际应用中应该完整翻译所有字段
  @override String get addFromCloudflare => '從 Cloudflare 新增';
  @override String get autoGetBestNodes => '自動獲取最優節點';
  @override String get manualAdd => '手動新增';
  @override String get inputServerInfo => '輸入伺服器資訊';
  @override String get scanQrCode => '掃描二維碼';
  @override String get importFromQrCode => '從二維碼導入配置';
  @override String get importFromClipboard => '從剪貼簿導入';
  @override String get pasteServerConfig => '貼上伺服器配置';
  @override String get diagnosticTool => '診斷工具';
  
  // 设置页面
  @override String get generalSettings => '通用設定';
  @override String get networkSettings => '網路設定';
  @override String get about => '關於';
  @override String get autoStart => '開機自啟';
  @override String get autoStartDesc => '系統啟動時自動運行';
  @override String get autoConnect => '自動連接';
  @override String get autoConnectDesc => '啟動應用時自動連接';
  @override String get tunMode => 'TUN 模式';
  @override String get tunModeDesc => '使用 TUN 虛擬網卡實現全局代理';
  @override String get proxyMode => '代理模式';
  @override String get globalProxy => '全局代理';
  @override String get routeSettings => '路由設定';
  @override String get configureRules => '配置分流規則';
  @override String get currentVersion => '當前版本';
  @override String get checkUpdate => '檢查更新';
  @override String get officialWebsite => '官方網站';
  @override String get contactEmail => '聯絡郵箱';
  @override String get privacyPolicy => '隱私政策';
  @override String get clearCache => '清除快取';
  @override String get cacheCleared => '快取已清除';
  @override String get language => '語言';
  @override String get theme => '主題';
  @override String get systemTheme => '跟隨系統';
  @override String get lightTheme => '淺色';
  @override String get darkTheme => '深色';
  
  // 消息
  @override String get operationFailed => '操作失敗';
  @override String get testingLatency => '正在測試延遲...';
  @override String get gettingNodes => '正在獲取節點...';
  @override String get noAvailableServer => '沒有可用的伺服器';
  @override String get alreadyLatestVersion => '已是最新版本';
  @override String get serverAdded => '伺服器已新增';
  @override String get serverDeleted => '伺服器已刪除';
  @override String get allServersDeleted => '所有伺服器已刪除';
  
  // Cloudflare测试
  @override String get nodeCount => '新增數量';
  @override String get maxLatency => '延遲上限';
  @override String get minSpeed => '最低網速';
  @override String get testSamples => '測試樣本數';
  @override String get startTest => '開始測試';
  @override String get testing => '測試中';
  @override String get testCompleted => '測試完成';
  @override String get testFailed => '測試失敗';
  @override String get preparing => '正在準備...';
  @override String get connectingNodes => '正在連接節點...';
  @override String get processingResults => '正在處理結果...';
  
  // 诊断
  @override String get runDiagnostics => '運行診斷';
  @override String get diagnosticResults => '診斷結果';
  @override String get fileCheck => '檔案檢查';
  @override String get networkTest => '網路測試';
  @override String get systemInfo => '系統資訊';
  
  // 退出确认
  @override String get confirmExit => '退出確認';
  @override String get confirmExitDesc => '請選擇操作：';
  @override String get minimize => '最小化到系統匣';
  @override String get exitApp => '退出應用';
}

// 西班牙语
class AppLocalizationsEs extends AppLocalizationsEn {
  @override String get appName => 'CFVPN';
  @override String get home => 'Inicio';
  @override String get servers => 'Servidores';
  @override String get settings => 'Ajustes';
  @override String get connect => 'Conectar';
  @override String get disconnect => 'Desconectar';
  @override String get connected => 'Conectado';
  @override String get disconnected => 'Desconectado';
  // ... 其他翻译
  
  // 退出确认
  @override String get confirmExit => 'Confirmar salida';
  @override String get confirmExitDesc => 'Elige una acción:';
  @override String get minimize => 'Minimizar a la bandeja';
  @override String get exitApp => 'Salir de la aplicación';
}

// 俄语
class AppLocalizationsRu extends AppLocalizationsEn {
  @override String get appName => 'CFVPN';
  @override String get home => 'Главная';
  @override String get servers => 'Серверы';
  @override String get settings => 'Настройки';
  @override String get connect => 'Подключить';
  @override String get disconnect => 'Отключить';
  @override String get connected => 'Подключено';
  @override String get disconnected => 'Отключено';
  // ... 其他翻译
  
  // 退出确认
  @override String get confirmExit => 'Подтверждение выхода';
  @override String get confirmExitDesc => 'Выберите действие:';
  @override String get minimize => 'Свернуть в трей';
  @override String get exitApp => 'Выйти из приложения';
}

// 阿拉伯语
class AppLocalizationsAr extends AppLocalizationsEn {
  @override String get appName => 'CFVPN';
  @override String get home => 'الرئيسية';
  @override String get servers => 'الخوادم';
  @override String get settings => 'الإعدادات';
  @override String get connect => 'اتصال';
  @override String get disconnect => 'قطع الاتصال';
  @override String get connected => 'متصل';
  @override String get disconnected => 'غير متصل';
  // ... 其他翻译
  
  // 退出确认
  @override String get confirmExit => 'تأكيد الخروج';
  @override String get confirmExitDesc => 'اختر إجراء:';
  @override String get minimize => 'تصغير إلى علبة النظام';
  @override String get exitApp => 'الخروج من التطبيق';
}