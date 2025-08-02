import 'package:flutter/material.dart';
import '../utils/location_utils.dart';

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
  
  /// 构建国旗图标组件
  static Widget buildCountryFlag(String countryCode, {double size = 30}) {
    final flagData = _getFlagData(countryCode);
    
    return Container(
      width: size,
      height: size * 0.75, // 矩形比例 4:3
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: flagData['colors'] as List<Color>,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(4), // 轻微圆角
        boxShadow: [
          BoxShadow(
            color: (flagData['colors'] as List<Color>)[0].withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          flagData['code'] as String,
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: [
              Shadow(
                color: Colors.black.withOpacity(0.3),
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
}