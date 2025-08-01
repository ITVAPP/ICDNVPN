// 地理位置工具类
class LocationUtils {
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