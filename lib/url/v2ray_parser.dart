// v2ray_parser.dart
import 'url.dart';
import 'vmess.dart';
import 'vless.dart';
import 'trojan.dart';
import 'shadowsocks.dart';
import 'socks.dart';

class V2RayParser {
  /// 解析分享链接
  static V2RayURL parseFromURL(String url) {
    // 获取协议类型
    String protocol = url.split("://")[0].toLowerCase();
    
    switch (protocol) {
      case 'vmess':
        return VmessURL(url: url);
      case 'vless':
        return VlessURL(url: url);
      case 'trojan':
        return TrojanURL(url: url);
      case 'ss':
        return ShadowSocksURL(url: url);
      case 'socks':
        return SocksURL(url: url);
      default:
        throw ArgumentError('Unsupported protocol: $protocol');
    }
  }
  
  /// 解析链接并直接返回JSON配置
  static String parseToJson(String url, {int indent = 2}) {
    V2RayURL config = parseFromURL(url);
    return config.getFullConfiguration(indent: indent);
  }
  
  /// 批量解析
  static List<V2RayURL> parseMultiple(List<String> urls) {
    List<V2RayURL> configs = [];
    for (String url in urls) {
      try {
        configs.add(parseFromURL(url));
      } catch (e) {
        print('Failed to parse: $url - $e');
      }
    }
    return configs;
  }
}