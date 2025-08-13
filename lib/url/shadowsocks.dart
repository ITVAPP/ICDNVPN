import 'dart:convert';
import 'url.dart'; 

class ShadowSocksURL extends V2RayURL {
  ShadowSocksURL({required super.url}) {
    if (!url.startsWith('ss://')) {
      throw ArgumentError('url is invalid');
    }
    
    // 预处理URL，处理编码问题
    String processedUrl = url;
    try {
      // 尝试解码URL中的特殊字符
      if (url.contains('%')) {
        processedUrl = Uri.decodeFull(url);
      }
    } catch (_) {
      // 如果解码失败，使用原始URL
    }
    
    final temp = Uri.tryParse(processedUrl);
    if (temp == null) {
      throw ArgumentError('url is invalid');
    }
    uri = temp;
    
    // 解析基础SS配置（method:password）
    if (uri.userInfo.isNotEmpty) {
      String raw = uri.userInfo;
      if (raw.length % 4 > 0) {
        raw += "=" * (4 - raw.length % 4);
      }
      try {
        final methodpass = utf8.decode(base64Decode(raw));
        // 查找第一个冒号位置，因为密码可能包含冒号
        int colonIndex = methodpass.indexOf(':');
        if (colonIndex > 0) {
          method = methodpass.substring(0, colonIndex);
          password = methodpass.substring(colonIndex + 1);
        }
      } catch (_) {
        // 解析失败，使用默认值
      }
    }

    // 检查是否有v2ray-plugin
    if (uri.queryParameters.containsKey('plugin')) {
      _parseV2RayPlugin(uri.queryParameters['plugin']!);
    } else {
      // 原有的标准参数解析
      _parseStandardParams();
    }
  }
  
  // 解析v2ray-plugin参数
  void _parseV2RayPlugin(String pluginParam) {
    // URL解码plugin参数
    String decodedPlugin = pluginParam;
    try {
      if (pluginParam.contains('%')) {
        decodedPlugin = Uri.decodeComponent(pluginParam);
      }
    } catch (_) {
      // 解码失败，使用原始值
    }
    
    // 检查是否是v2ray-plugin
    if (!decodedPlugin.startsWith('v2ray-plugin')) {
      // 不是v2ray-plugin，回退到标准解析
      _parseStandardParams();
      return;
    }
    
    // 默认值
    String transport = "tcp";
    String security = "";
    String? host;
    String? path;
    String? mode;
    Map<String, String> headers = {};
    
    // 解析插件参数 (格式: v2ray-plugin;param1=value1;param2=value2;tls)
    List<String> parts = decodedPlugin.split(';');
    
    for (int i = 1; i < parts.length; i++) {
      String part = parts[i].trim();
      
      if (part.isEmpty) continue;
      
      // 无值参数（如tls）
      if (!part.contains('=')) {
        switch (part.toLowerCase()) {
          case 'tls':
            security = 'tls';
            break;
          case 'quic':
            transport = 'quic';
            break;
        }
        continue;
      }
      
      // 键值对参数
      int equalIndex = part.indexOf('=');
      if (equalIndex > 0) {
        String key = part.substring(0, equalIndex).trim();
        String value = part.substring(equalIndex + 1).trim();
        
        switch (key.toLowerCase()) {
          case 'host':
            host = value;
            break;
          case 'path':
            path = value;
            break;
          case 'mode':
            mode = value.toLowerCase();
            break;
          case 'header':
            // 处理自定义header
            if (value.contains(':')) {
              var headerParts = value.split(':');
              headers[headerParts[0]] = headerParts.sublist(1).join(':');
            }
            break;
        }
      }
    }
    
    // 根据mode或其他参数确定传输协议
    if (mode != null) {
      switch (mode) {
        case 'websocket':
        case 'ws':
          transport = 'ws';
          break;
        case 'quic':
          transport = 'quic';
          break;
        case 'http':
        case 'h2':
        case 'http2':
          transport = 'h2';
          break;
        case 'grpc':
          transport = 'grpc';
          break;
      }
    } else if (path != null && path.isNotEmpty) {
      // 有path通常表示WebSocket
      transport = 'ws';
    }
    
    // 设置传输层
    var sni = super.populateTransportSettings(
      transport: transport,
      headerType: transport == 'tcp' ? 'none' : null,
      host: host,
      path: path,
      seed: null,
      quicSecurity: transport == 'quic' ? 'none' : null,
      key: null,
      mode: null,
      serviceName: transport == 'grpc' ? (path ?? '') : null,
    );
    
    // 设置TLS/Security
    if (security.isNotEmpty) {
      super.populateTlsSettings(
        streamSecurity: security,
        allowInsecure: allowInsecure,
        sni: host ?? sni,
        fingerprint: streamSetting['tlsSettings']?['fingerprint'],
        alpns: null,
        publicKey: null,
        shortId: null,
        spiderX: null,
      );
    }
  }
  
  // 解析标准SS参数（兼容原有格式）
  void _parseStandardParams() {
    if (uri.queryParameters.isNotEmpty) {
      // 原有的参数解析逻辑
      var sni = super.populateTransportSettings(
        transport: uri.queryParameters['type'] ?? "tcp",
        headerType: uri.queryParameters['headerType'],
        host: uri.queryParameters["host"],
        path: uri.queryParameters["path"],
        seed: uri.queryParameters["seed"],
        quicSecurity: uri.queryParameters["quicSecurity"],
        key: uri.queryParameters["key"],
        mode: uri.queryParameters["mode"],
        serviceName: uri.queryParameters["serviceName"],
      );
      
      super.populateTlsSettings(
        streamSecurity: uri.queryParameters['security'] ?? '',
        allowInsecure: allowInsecure,
        sni: uri.queryParameters["sni"] ?? sni,
        fingerprint: streamSetting['tlsSettings']?['fingerprint'],
        alpns: uri.queryParameters['alpn'],
        publicKey: null,
        shortId: null,
        spiderX: null,
      );
    }
  }

  @override
  String get address => uri.host;

  @override
  int get port => uri.hasPort ? uri.port : super.port;

  @override
  String get remark {
    try {
      return Uri.decodeFull(uri.fragment.replaceAll('+', '%20'));
    } catch (_) {
      return uri.fragment.replaceAll('+', ' ');
    }
  }

  late final Uri uri;

  String method = "none";

  String password = "";

  @override
  Map<String, dynamic> get outbound1 => {
        "tag": "proxy",
        "protocol": "shadowsocks",
        "settings": {
          "vnext": null,
          "servers": [
            {
              "address": address,
              "method": method,
              "ota": false,
              "password": password,
              "port": port,
              "level": level,
              "email": null,
              "flow": null,
              "ivCheck": null,
              "users": null
            }
          ],
          "response": null,
          "network": null,
          "address": null,
          "port": null,
          "domainStrategy": null,
          "redirect": null,
          "userLevel": null,
          "inboundTag": null,
          "secretKey": null,
          "peers": null
        },
        "streamSettings": streamSetting,
        "proxySettings": null,
        "sendThrough": null,
        "mux": {"enabled": false, "concurrency": 8}
      };
}