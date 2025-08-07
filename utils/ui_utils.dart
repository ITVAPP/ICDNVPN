import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

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
  
  // 国家代码到emoji标志的映射（保留用于显示emoji）
  static final Map<String, String> _countryFlags = {
    // 亚洲
    'CN': '🇨🇳',
    'HK': '🇭🇰',
    'TW': '🇹🇼',
    'SG': '🇸🇬',
    'JP': '🇯🇵',
    'KR': '🇰🇷',
    'TH': '🇹🇭',
    'MY': '🇲🇾',
    'PH': '🇵🇭',
    'ID': '🇮🇩',
    'IN': '🇮🇳',
    'AE': '🇦🇪',
    'VN': '🇻🇳',
    'TR': '🇹🇷',
    'IL': '🇮🇱',
    
    // 北美洲
    'US': '🇺🇸',
    'CA': '🇨🇦',
    'MX': '🇲🇽',
    
    // 欧洲
    'GB': '🇬🇧',
    'FR': '🇫🇷',
    'DE': '🇩🇪',
    'NL': '🇳🇱',
    'ES': '🇪🇸',
    'IT': '🇮🇹',
    'CH': '🇨🇭',
    'AT': '🇦🇹',
    'SE': '🇸🇪',
    'DK': '🇩🇰',
    'PL': '🇵🇱',
    'RU': '🇷🇺',
    'BE': '🇧🇪',
    'CZ': '🇨🇿',
    'FI': '🇫🇮',
    'IE': '🇮🇪',
    'NO': '🇳🇴',
    'PT': '🇵🇹',
    'GR': '🇬🇷',
    'RO': '🇷🇴',
    'UA': '🇺🇦',
    
    // 大洋洲
    'AU': '🇦🇺',
    'NZ': '🇳🇿',
    
    // 南美洲
    'BR': '🇧🇷',
    'AR': '🇦🇷',
    'CL': '🇨🇱',
    'PE': '🇵🇪',
    'CO': '🇨🇴',
    'VE': '🇻🇪',
    'UY': '🇺🇾',
    
    // 非洲
    'ZA': '🇿🇦',
    'EG': '🇪🇬',
    'NG': '🇳🇬',
    'KE': '🇰🇪',
    'MA': '🇲🇦',
    'TN': '🇹🇳',
    'ET': '🇪🇹',
  };
  
  // 国家代码到大洲的映射
  static final Map<String, String> _countryToContinent = {
    // 亚洲
    'CN': 'Asia',
    'HK': 'Asia',
    'TW': 'Asia',
    'SG': 'Asia',
    'JP': 'Asia',
    'KR': 'Asia',
    'TH': 'Asia',
    'MY': 'Asia',
    'PH': 'Asia',
    'ID': 'Asia',
    'IN': 'Asia',
    'AE': 'Asia',
    'VN': 'Asia',
    'TR': 'Asia',
    'IL': 'Asia',
    
    // 北美洲
    'US': 'NorthAmerica',
    'CA': 'NorthAmerica',
    'MX': 'NorthAmerica',
    
    // 欧洲
    'GB': 'Europe',
    'FR': 'Europe',
    'DE': 'Europe',
    'NL': 'Europe',
    'ES': 'Europe',
    'IT': 'Europe',
    'CH': 'Europe',
    'AT': 'Europe',
    'SE': 'Europe',
    'DK': 'Europe',
    'PL': 'Europe',
    'RU': 'Europe',
    'BE': 'Europe',
    'CZ': 'Europe',
    'FI': 'Europe',
    'IE': 'Europe',
    'NO': 'Europe',
    'PT': 'Europe',
    'GR': 'Europe',
    'RO': 'Europe',
    'UA': 'Europe',
    
    // 大洋洲
    'AU': 'Oceania',
    'NZ': 'Oceania',
    
    // 南美洲
    'BR': 'SouthAmerica',
    'AR': 'SouthAmerica',
    'CL': 'SouthAmerica',
    'PE': 'SouthAmerica',
    'CO': 'SouthAmerica',
    'VE': 'SouthAmerica',
    'UY': 'SouthAmerica',
    
    // 非洲
    'ZA': 'Africa',
    'EG': 'Africa',
    'NG': 'Africa',
    'KE': 'Africa',
    'MA': 'Africa',
    'TN': 'Africa',
    'ET': 'Africa',
  };
  
  // 默认的英文国家名称映射（用于向后兼容）
  static final Map<String, String> _defaultCountryNames = {
    // 亚洲
    'CN': 'China',
    'HK': 'Hong Kong',
    'TW': 'Taiwan',
    'SG': 'Singapore',
    'JP': 'Japan',
    'KR': 'South Korea',
    'TH': 'Thailand',
    'MY': 'Malaysia',
    'PH': 'Philippines',
    'ID': 'Indonesia',
    'IN': 'India',
    'AE': 'UAE',
    'VN': 'Vietnam',
    'TR': 'Turkey',
    'IL': 'Israel',
    
    // 北美洲
    'US': 'United States',
    'CA': 'Canada',
    'MX': 'Mexico',
    
    // 欧洲
    'GB': 'United Kingdom',
    'FR': 'France',
    'DE': 'Germany',
    'NL': 'Netherlands',
    'ES': 'Spain',
    'IT': 'Italy',
    'CH': 'Switzerland',
    'AT': 'Austria',
    'SE': 'Sweden',
    'DK': 'Denmark',
    'PL': 'Poland',
    'RU': 'Russia',
    'BE': 'Belgium',
    'CZ': 'Czechia',
    'FI': 'Finland',
    'IE': 'Ireland',
    'NO': 'Norway',
    'PT': 'Portugal',
    'GR': 'Greece',
    'RO': 'Romania',
    'UA': 'Ukraine',
    
    // 大洋洲
    'AU': 'Australia',
    'NZ': 'New Zealand',
    
    // 南美洲
    'BR': 'Brazil',
    'AR': 'Argentina',
    'CL': 'Chile',
    'PE': 'Peru',
    'CO': 'Colombia',
    'VE': 'Venezuela',
    'UY': 'Uruguay',
    
    // 非洲
    'ZA': 'South Africa',
    'EG': 'Egypt',
    'NG': 'Nigeria',
    'KE': 'Kenya',
    'MA': 'Morocco',
    'TN': 'Tunisia',
    'ET': 'Ethiopia',
  };
  
  // 默认的英文大洲名称（用于向后兼容）
  static final Map<String, String> _defaultContinentNames = {
    'Asia': 'Asia',
    'NorthAmerica': 'North America',
    'Europe': 'Europe',
    'Oceania': 'Oceania',
    'SouthAmerica': 'South America',
    'Africa': 'Africa',
    'Unknown': 'Unknown',
  };
  
  // 获取本地化的国家名称
  static String getLocalizedCountryName(BuildContext context, String code) {
    final l10n = AppLocalizations.of(context);
    final upperCode = code.toUpperCase();
    
    // 根据国家代码返回本地化的名称
    switch (upperCode) {
      // 亚洲
      case 'CN': return l10n.countryChina;
      case 'HK': return l10n.countryHongKong;
      case 'TW': return l10n.countryTaiwan;
      case 'SG': return l10n.countrySingapore;
      case 'JP': return l10n.countryJapan;
      case 'KR': return l10n.countrySouthKorea;
      case 'TH': return l10n.countryThailand;
      case 'MY': return l10n.countryMalaysia;
      case 'PH': return l10n.countryPhilippines;
      case 'ID': return l10n.countryIndonesia;
      case 'IN': return l10n.countryIndia;
      case 'AE': return l10n.countryUAE;
      case 'VN': return l10n.countryVietnam;
      case 'TR': return l10n.countryTurkey;
      case 'IL': return l10n.countryIsrael;
      
      // 北美洲
      case 'US': return l10n.countryUSA;
      case 'CA': return l10n.countryCanada;
      case 'MX': return l10n.countryMexico;
      
      // 欧洲
      case 'GB': return l10n.countryUK;
      case 'FR': return l10n.countryFrance;
      case 'DE': return l10n.countryGermany;
      case 'NL': return l10n.countryNetherlands;
      case 'ES': return l10n.countrySpain;
      case 'IT': return l10n.countryItaly;
      case 'CH': return l10n.countrySwitzerland;
      case 'AT': return l10n.countryAustria;
      case 'SE': return l10n.countrySweden;
      case 'DK': return l10n.countryDenmark;
      case 'PL': return l10n.countryPoland;
      case 'RU': return l10n.countryRussia;
      case 'BE': return l10n.countryBelgium;
      case 'CZ': return l10n.countryCzechia;
      case 'FI': return l10n.countryFinland;
      case 'IE': return l10n.countryIreland;
      case 'NO': return l10n.countryNorway;
      case 'PT': return l10n.countryPortugal;
      case 'GR': return l10n.countryGreece;
      case 'RO': return l10n.countryRomania;
      case 'UA': return l10n.countryUkraine;
      
      // 大洋洲
      case 'AU': return l10n.countryAustralia;
      case 'NZ': return l10n.countryNewZealand;
      
      // 南美洲
      case 'BR': return l10n.countryBrazil;
      case 'AR': return l10n.countryArgentina;
      case 'CL': return l10n.countryChile;
      case 'PE': return l10n.countryPeru;
      case 'CO': return l10n.countryColombia;
      case 'VE': return l10n.countryVenezuela;
      case 'UY': return l10n.countryUruguay;
      
      // 非洲
      case 'ZA': return l10n.countrySouthAfrica;
      case 'EG': return l10n.countryEgypt;
      case 'NG': return l10n.countryNigeria;
      case 'KE': return l10n.countryKenya;
      case 'MA': return l10n.countryMorocco;
      case 'TN': return l10n.countryTunisia;
      case 'ET': return l10n.countryEthiopia;
      
      default: return code; // 如果没有找到，返回原始代码
    }
  }
  
  // 获取本地化的大洲名称
  static String getLocalizedContinentName(BuildContext context, String continent) {
    final l10n = AppLocalizations.of(context);
    
    switch (continent) {
      case 'Asia': return l10n.continentAsia;
      case 'NorthAmerica': return l10n.continentNorthAmerica;
      case 'Europe': return l10n.continentEurope;
      case 'Oceania': return l10n.continentOceania;
      case 'SouthAmerica': return l10n.continentSouthAmerica;
      case 'Africa': return l10n.continentAfrica;
      default: return l10n.continentUnknown;
    }
  }
  
  // 获取位置信息（保持向后兼容的版本，不需要context）
  static Map<String, String> getLocationInfo(String code) {
    final upperCode = code.toUpperCase();
    
    // 获取默认的英文国家名称
    final countryName = _defaultCountryNames[upperCode] ?? code;
    
    // 获取emoji标志
    final flag = _countryFlags[upperCode] ?? '🌐';
    
    // 获取大洲
    final continentCode = _countryToContinent[upperCode] ?? 'Unknown';
    final continentName = _defaultContinentNames[continentCode] ?? 'Unknown';
    
    return {
      'country': countryName,
      'flag': flag,
      'continent': continentName,
    };
  }
  
  // 获取位置信息（使用国际化的新版本）
  static Map<String, String> getLocalizedLocationInfo(String code, BuildContext context) {
    final upperCode = code.toUpperCase();
    
    // 获取本地化的国家名称
    final countryName = getLocalizedCountryName(context, upperCode);
    
    // 获取emoji标志
    final flag = _countryFlags[upperCode] ?? '🌐';
    
    // 获取大洲
    final continentCode = _countryToContinent[upperCode] ?? 'Unknown';
    final continentName = getLocalizedContinentName(context, continentCode);
    
    return {
      'country': countryName,
      'flag': flag,
      'continent': continentName,
    };
  }
  
  // 获取所有支持的国家代码
  static List<String> getAllLocationCodes() {
    return _countryFlags.keys.toList()..sort();
  }
  
  // 根据国家获取国家代码列表（向后兼容版本）
  static List<String> getCodesByCountry(String country) {
    final codes = <String>[];
    _defaultCountryNames.forEach((code, name) {
      if (name == country) {
        codes.add(code);
      }
    });
    return codes;
  }
  
  // 根据大洲获取国家代码列表
  static List<String> getCodesByContinent(String continent) {
    final codes = <String>[];
    _countryToContinent.forEach((code, cont) {
      if (cont == continent) {
        codes.add(code);
      }
    });
    return codes;
  }
  
  // 获取国家名称（向后兼容版本，不需要context）
  static String getCountryName(String code) {
    final upperCode = code.toUpperCase();
    return _defaultCountryNames[upperCode] ?? code;
  }
  
  // 获取国家名称（新版本，需要context）
  static String getLocalizedCountryName2(String code, BuildContext context) {
    return getLocalizedCountryName(context, code);
  }
  
  // 获取国家旗帜emoji
  static String getCountryFlag(String code) {
    final upperCode = code.toUpperCase();
    return _countryFlags[upperCode] ?? '🌐';
  }
}