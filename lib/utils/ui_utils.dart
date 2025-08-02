import 'package:flutter/material.dart';

/// UI相关的工具类，包含通用的UI辅助方法
class UIUtils {
  
  /// 根据延迟值获取对应的颜色
  static Color getPingColor(int ping) {
    if (ping < 50) return Colors.green;
    if (ping < 100) return Colors.lightGreen;
    if (ping < 150) return Colors.orange;
    if (ping < 200) return Colors.deepOrange;
    return Colors.red;
  }
  
  /// 格式化字节数为可读格式
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  
  /// 格式化速度（字节/秒）
  static String formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond < 1024) return '$bytesPerSecond B/s';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  
  /// 构建国旗图标组件 - 圆形设计（纯色+描边）
  static Widget buildCountryFlag(String countryCode, {double size = 30}) {
    final flagData = _getFlagData(countryCode);
    
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: (flagData['colors'] as List<Color>)[0], // 使用纯色，不使用渐变
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withOpacity(0.8), // 白色描边
          width: 2,
        ),
        boxShadow: [
          // 外层阴影，增强立体感
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
          // 内层阴影，使描边更明显
          BoxShadow(
            color: (flagData['colors'] as List<Color>)[0].withOpacity(0.4),
            blurRadius: 8,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Center(
        child: Text(
          flagData['code'] as String,
          style: TextStyle(
            fontSize: size * 0.35,
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
    );
  }
  
  // 获取国旗数据 - 基于国家代码
  static Map<String, dynamic> _getFlagData(String code) {
    final upperCode = code.toUpperCase();
    
    // 定义每个国家的颜色和显示代码
    final flagMap = {
      // 亚洲
      'CN': {
        'colors': [const Color(0xFFDE2910), const Color(0xFFFF0000)],
        'code': 'CN',
      },
      'HK': {
        'colors': [const Color(0xFFDE2910), const Color(0xFFFF0000)],
        'code': 'HK',
      },
      'TW': {
        'colors': [const Color(0xFFFE0000), const Color(0xFF000095)],
        'code': 'TW',
      },
      'SG': {
        'colors': [const Color(0xFFED2939), const Color(0xFFFF0000)],
        'code': 'SG',
      },
      'JP': {
        'colors': [const Color(0xFFBC002D), const Color(0xFFFFFFFF)],
        'code': 'JP',
      },
      'KR': {
        'colors': [const Color(0xFF003478), const Color(0xFFC60C30)],
        'code': 'KR',
      },
      'TH': {
        'colors': [const Color(0xFFA51931), const Color(0xFFF4F5F8)],
        'code': 'TH',
      },
      'MY': {
        'colors': [const Color(0xFFCC0001), const Color(0xFF0032A0)],
        'code': 'MY',
      },
      'PH': {
        'colors': [const Color(0xFF0038A8), const Color(0xFFCE1126)],
        'code': 'PH',
      },
      'ID': {
        'colors': [const Color(0xFFFF0000), const Color(0xFFFFFFFF)],
        'code': 'ID',
      },
      'IN': {
        'colors': [const Color(0xFFFF9933), const Color(0xFF138808)],
        'code': 'IN',
      },
      'AE': {
        'colors': [const Color(0xFF00732F), const Color(0xFFFF0000)],
        'code': 'AE',
      },
      'VN': {
        'colors': [const Color(0xFFDA251D), const Color(0xFFFFFF00)],
        'code': 'VN',
      },
      
      // 北美洲
      'US': {
        'colors': [const Color(0xFF002868), const Color(0xFFBF0A30)],
        'code': 'US',
      },
      'CA': {
        'colors': [const Color(0xFFFF0000), const Color(0xFFFFFFFF)],
        'code': 'CA',
      },
      'MX': {
        'colors': [const Color(0xFF006847), const Color(0xFFCE1126)],
        'code': 'MX',
      },
      
      // 欧洲
      'GB': {
        'colors': [const Color(0xFF012169), const Color(0xFFC8102E)],
        'code': 'GB',
      },
      'FR': {
        'colors': [const Color(0xFF002395), const Color(0xFFED2939)],
        'code': 'FR',
      },
      'DE': {
        'colors': [const Color(0xFF000000), const Color(0xFFDD0000)],
        'code': 'DE',
      },
      'NL': {
        'colors': [const Color(0xFFAE1C28), const Color(0xFF21468B)],
        'code': 'NL',
      },
      'ES': {
        'colors': [const Color(0xFFAA151B), const Color(0xFFF1BF00)],
        'code': 'ES',
      },
      'IT': {
        'colors': [const Color(0xFF009246), const Color(0xFFCE2B37)],
        'code': 'IT',
      },
      'CH': {
        'colors': [const Color(0xFFFF0000), const Color(0xFFFFFFFF)],
        'code': 'CH',
      },
      'AT': {
        'colors': [const Color(0xFFED2939), const Color(0xFFFFFFFF)],
        'code': 'AT',
      },
      'SE': {
        'colors': [const Color(0xFF006AA7), const Color(0xFFFECC00)],
        'code': 'SE',
      },
      'DK': {
        'colors': [const Color(0xFFC8102E), const Color(0xFFFFFFFF)],
        'code': 'DK',
      },
      'PL': {
        'colors': [const Color(0xFFDC143C), const Color(0xFFFFFFFF)],
        'code': 'PL',
      },
      'RU': {
        'colors': [const Color(0xFF0039A6), const Color(0xFFD52B1E)],
        'code': 'RU',
      },
      'BE': {
        'colors': [const Color(0xFFFDDA24), const Color(0xFFEF3340)],
        'code': 'BE',
      },
      'CZ': {
        'colors': [const Color(0xFF11457E), const Color(0xFFD7141A)],
        'code': 'CZ',
      },
      'FI': {
        'colors': [const Color(0xFF003580), const Color(0xFFFFFFFF)],
        'code': 'FI',
      },
      'IE': {
        'colors': [const Color(0xFF169B62), const Color(0xFFFF883E)],
        'code': 'IE',
      },
      'NO': {
        'colors': [const Color(0xFFBA0C2F), const Color(0xFF00205B)],
        'code': 'NO',
      },
      'PT': {
        'colors': [const Color(0xFF006600), const Color(0xFFFF0000)],
        'code': 'PT',
      },
      
      // 大洋洲
      'AU': {
        'colors': [const Color(0xFF012169), const Color(0xFFE4002B)],
        'code': 'AU',
      },
      'NZ': {
        'colors': [const Color(0xFF012169), const Color(0xFFC8102E)],
        'code': 'NZ',
      },
      
      // 南美洲
      'BR': {
        'colors': [const Color(0xFF009B3A), const Color(0xFFFEDF00)],
        'code': 'BR',
      },
      'AR': {
        'colors': [const Color(0xFF75AADB), const Color(0xFFFFFFFF)],
        'code': 'AR',
      },
      'CL': {
        'colors': [const Color(0xFFD52B1E), const Color(0xFF0039A6)],
        'code': 'CL',
      },
      'PE': {
        'colors': [const Color(0xFFD91023), const Color(0xFFFFFFFF)],
        'code': 'PE',
      },
      'CO': {
        'colors': [const Color(0xFFFCD116), const Color(0xFF003893)],
        'code': 'CO',
      },
      
      // 非洲
      'ZA': {
        'colors': [const Color(0xFF007A4D), const Color(0xFFFFB612)],
        'code': 'ZA',
      },
      'EG': {
        'colors': [const Color(0xFFCE1126), const Color(0xFF000000)],
        'code': 'EG',
      },
      'NG': {
        'colors': [const Color(0xFF008751), const Color(0xFFFFFFFF)],
        'code': 'NG',
      },
      'KE': {
        'colors': [const Color(0xFF006600), const Color(0xFFBB0000)],
        'code': 'KE',
      },
      'MA': {
        'colors': [const Color(0xFFC1272D), const Color(0xFF006233)],
        'code': 'MA',
      },
    };
    
    // 如果找不到对应的代码，返回默认的全球图标
    return flagMap[upperCode] ?? {
      'colors': [Colors.blue.shade600, Colors.blue.shade400],
      'code': '🌐',
    };
  }
  
  // ===== 地理位置工具（从 location_utils.dart 合并） =====
  
  // 国家代码到国家信息的映射
  static final Map<String, Map<String, String>> _locationMapping = {
    // 亚洲
    'CN': {'country': '中国', 'flag': '🇨🇳', 'continent': '亚洲'},
    'HK': {'country': '香港', 'flag': '🇭🇰', 'continent': '亚洲'},
    'TW': {'country': '台湾', 'flag': '🇹🇼', 'continent': '亚洲'},
    'SG': {'country': '新加坡', 'flag': '🇸🇬', 'continent': '亚洲'},
    'JP': {'country': '日本', 'flag': '🇯🇵', 'continent': '亚洲'},
    'KR': {'country': '韩国', 'flag': '🇰🇷', 'continent': '亚洲'},
    'TH': {'country': '泰国', 'flag': '🇹🇭', 'continent': '亚洲'},
    'MY': {'country': '马来西亚', 'flag': '🇲🇾', 'continent': '亚洲'},
    'PH': {'country': '菲律宾', 'flag': '🇵🇭', 'continent': '亚洲'},
    'ID': {'country': '印度尼西亚', 'flag': '🇮🇩', 'continent': '亚洲'},
    'IN': {'country': '印度', 'flag': '🇮🇳', 'continent': '亚洲'},
    'AE': {'country': '阿联酋', 'flag': '🇦🇪', 'continent': '亚洲'},
    'VN': {'country': '越南', 'flag': '🇻🇳', 'continent': '亚洲'},
    'TR': {'country': '土耳其', 'flag': '🇹🇷', 'continent': '亚洲'},
    'IL': {'country': '以色列', 'flag': '🇮🇱', 'continent': '亚洲'},
    
    // 北美洲
    'US': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'CA': {'country': '加拿大', 'flag': '🇨🇦', 'continent': '北美洲'},
    'MX': {'country': '墨西哥', 'flag': '🇲🇽', 'continent': '北美洲'},
    
    // 欧洲
    'GB': {'country': '英国', 'flag': '🇬🇧', 'continent': '欧洲'},
    'FR': {'country': '法国', 'flag': '🇫🇷', 'continent': '欧洲'},
    'DE': {'country': '德国', 'flag': '🇩🇪', 'continent': '欧洲'},
    'NL': {'country': '荷兰', 'flag': '🇳🇱', 'continent': '欧洲'},
    'ES': {'country': '西班牙', 'flag': '🇪🇸', 'continent': '欧洲'},
    'IT': {'country': '意大利', 'flag': '🇮🇹', 'continent': '欧洲'},
    'CH': {'country': '瑞士', 'flag': '🇨🇭', 'continent': '欧洲'},
    'AT': {'country': '奥地利', 'flag': '🇦🇹', 'continent': '欧洲'},
    'SE': {'country': '瑞典', 'flag': '🇸🇪', 'continent': '欧洲'},
    'DK': {'country': '丹麦', 'flag': '🇩🇰', 'continent': '欧洲'},
    'PL': {'country': '波兰', 'flag': '🇵🇱', 'continent': '欧洲'},
    'RU': {'country': '俄罗斯', 'flag': '🇷🇺', 'continent': '欧洲'},
    'BE': {'country': '比利时', 'flag': '🇧🇪', 'continent': '欧洲'},
    'CZ': {'country': '捷克', 'flag': '🇨🇿', 'continent': '欧洲'},
    'FI': {'country': '芬兰', 'flag': '🇫🇮', 'continent': '欧洲'},
    'IE': {'country': '爱尔兰', 'flag': '🇮🇪', 'continent': '欧洲'},
    'NO': {'country': '挪威', 'flag': '🇳🇴', 'continent': '欧洲'},
    'PT': {'country': '葡萄牙', 'flag': '🇵🇹', 'continent': '欧洲'},
    'GR': {'country': '希腊', 'flag': '🇬🇷', 'continent': '欧洲'},
    'RO': {'country': '罗马尼亚', 'flag': '🇷🇴', 'continent': '欧洲'},
    'UA': {'country': '乌克兰', 'flag': '🇺🇦', 'continent': '欧洲'},
    
    // 大洋洲
    'AU': {'country': '澳大利亚', 'flag': '🇦🇺', 'continent': '大洋洲'},
    'NZ': {'country': '新西兰', 'flag': '🇳🇿', 'continent': '大洋洲'},
    
    // 南美洲
    'BR': {'country': '巴西', 'flag': '🇧🇷', 'continent': '南美洲'},
    'AR': {'country': '阿根廷', 'flag': '🇦🇷', 'continent': '南美洲'},
    'CL': {'country': '智利', 'flag': '🇨🇱', 'continent': '南美洲'},
    'PE': {'country': '秘鲁', 'flag': '🇵🇪', 'continent': '南美洲'},
    'CO': {'country': '哥伦比亚', 'flag': '🇨🇴', 'continent': '南美洲'},
    'VE': {'country': '委内瑞拉', 'flag': '🇻🇪', 'continent': '南美洲'},
    'UY': {'country': '乌拉圭', 'flag': '🇺🇾', 'continent': '南美洲'},
    
    // 非洲
    'ZA': {'country': '南非', 'flag': '🇿🇦', 'continent': '非洲'},
    'EG': {'country': '埃及', 'flag': '🇪🇬', 'continent': '非洲'},
    'NG': {'country': '尼日利亚', 'flag': '🇳🇬', 'continent': '非洲'},
    'KE': {'country': '肯尼亚', 'flag': '🇰🇪', 'continent': '非洲'},
    'MA': {'country': '摩洛哥', 'flag': '🇲🇦', 'continent': '非洲'},
    'TN': {'country': '突尼斯', 'flag': '🇹🇳', 'continent': '非洲'},
    'ET': {'country': '埃塞俄比亚', 'flag': '🇪🇹', 'continent': '非洲'},
  };
  
  // 获取位置信息
  static Map<String, String> getLocationInfo(String code) {
    // 将代码转换为大写
    final upperCode = code.toUpperCase();
    
    // 如果找到对应的映射，返回映射信息
    if (_locationMapping.containsKey(upperCode)) {
      return _locationMapping[upperCode]!;
    }
    
    // 如果没有找到，返回默认值
    return {
      'country': code,
      'flag': '🌐',
      'continent': '未知',
    };
  }
  
  // 获取所有支持的国家代码
  static List<String> getAllLocationCodes() {
    return _locationMapping.keys.toList()..sort();
  }
  
  // 根据国家获取国家代码列表
  static List<String> getCodesByCountry(String country) {
    final codes = <String>[];
    _locationMapping.forEach((code, info) {
      if (info['country'] == country) {
        codes.add(code);
      }
    });
    return codes;
  }
  
  // 根据大洲获取国家代码列表
  static List<String> getCodesByContinent(String continent) {
    final codes = <String>[];
    _locationMapping.forEach((code, info) {
      if (info['continent'] == continent) {
        codes.add(code);
      }
    });
    return codes;
  }
  
  // 获取国家名称（用于显示）
  static String getCountryName(String code) {
    final info = getLocationInfo(code);
    return info['country'] ?? code;
  }
  
  // 获取国家旗帜emoji
  static String getCountryFlag(String code) {
    final info = getLocationInfo(code);
    return info['flag'] ?? '🌐';
  }
}