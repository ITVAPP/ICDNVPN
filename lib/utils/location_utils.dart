// 地理位置工具类
class LocationUtils {
  // 机场代码到国家/地区的映射
  static final Map<String, Map<String, String>> _locationMapping = {
    // 亚洲
    'HKG': {'country': '香港', 'flag': '🇭🇰', 'continent': '亚洲'},
    'SIN': {'country': '新加坡', 'flag': '🇸🇬', 'continent': '亚洲'},
    'NRT': {'country': '日本', 'flag': '🇯🇵', 'continent': '亚洲'},
    'KIX': {'country': '日本', 'flag': '🇯🇵', 'continent': '亚洲'},
    'ICN': {'country': '韩国', 'flag': '🇰🇷', 'continent': '亚洲'},
    'TPE': {'country': '台湾', 'flag': '🇹🇼', 'continent': '亚洲'},
    'BKK': {'country': '泰国', 'flag': '🇹🇭', 'continent': '亚洲'},
    'KUL': {'country': '马来西亚', 'flag': '🇲🇾', 'continent': '亚洲'},
    'MNL': {'country': '菲律宾', 'flag': '🇵🇭', 'continent': '亚洲'},
    'CGK': {'country': '印度尼西亚', 'flag': '🇮🇩', 'continent': '亚洲'},
    'BOM': {'country': '印度', 'flag': '🇮🇳', 'continent': '亚洲'},
    'DEL': {'country': '印度', 'flag': '🇮🇳', 'continent': '亚洲'},
    'DXB': {'country': '阿联酋', 'flag': '🇦🇪', 'continent': '亚洲'},
    
    // 北美洲
    'LAX': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'SFO': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'SEA': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'ORD': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'JFK': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'IAD': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'MIA': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'DFW': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'ATL': {'country': '美国', 'flag': '🇺🇸', 'continent': '北美洲'},
    'YYZ': {'country': '加拿大', 'flag': '🇨🇦', 'continent': '北美洲'},
    'YVR': {'country': '加拿大', 'flag': '🇨🇦', 'continent': '北美洲'},
    
    // 欧洲
    'LHR': {'country': '英国', 'flag': '🇬🇧', 'continent': '欧洲'},
    'MAN': {'country': '英国', 'flag': '🇬🇧', 'continent': '欧洲'},
    'CDG': {'country': '法国', 'flag': '🇫🇷', 'continent': '欧洲'},
    'FRA': {'country': '德国', 'flag': '🇩🇪', 'continent': '欧洲'},
    'AMS': {'country': '荷兰', 'flag': '🇳🇱', 'continent': '欧洲'},
    'MAD': {'country': '西班牙', 'flag': '🇪🇸', 'continent': '欧洲'},
    'MXP': {'country': '意大利', 'flag': '🇮🇹', 'continent': '欧洲'},
    'ZRH': {'country': '瑞士', 'flag': '🇨🇭', 'continent': '欧洲'},
    'VIE': {'country': '奥地利', 'flag': '🇦🇹', 'continent': '欧洲'},
    'STO': {'country': '瑞典', 'flag': '🇸🇪', 'continent': '欧洲'},
    'ARN': {'country': '瑞典', 'flag': '🇸🇪', 'continent': '欧洲'},
    'CPH': {'country': '丹麦', 'flag': '🇩🇰', 'continent': '欧洲'},
    'WAW': {'country': '波兰', 'flag': '🇵🇱', 'continent': '欧洲'},
    'SVO': {'country': '俄罗斯', 'flag': '🇷🇺', 'continent': '欧洲'},
    'DME': {'country': '俄罗斯', 'flag': '🇷🇺', 'continent': '欧洲'},
    
    // 大洋洲
    'SYD': {'country': '澳大利亚', 'flag': '🇦🇺', 'continent': '大洋洲'},
    'MEL': {'country': '澳大利亚', 'flag': '🇦🇺', 'continent': '大洋洲'},
    'BNE': {'country': '澳大利亚', 'flag': '🇦🇺', 'continent': '大洋洲'},
    'AKL': {'country': '新西兰', 'flag': '🇳🇿', 'continent': '大洋洲'},
    
    // 南美洲
    'GRU': {'country': '巴西', 'flag': '🇧🇷', 'continent': '南美洲'},
    'GIG': {'country': '巴西', 'flag': '🇧🇷', 'continent': '南美洲'},
    'EZE': {'country': '阿根廷', 'flag': '🇦🇷', 'continent': '南美洲'},
    'SCL': {'country': '智利', 'flag': '🇨🇱', 'continent': '南美洲'},
    'LIM': {'country': '秘鲁', 'flag': '🇵🇪', 'continent': '南美洲'},
    
    // 非洲
    'JNB': {'country': '南非', 'flag': '🇿🇦', 'continent': '非洲'},
    'CPT': {'country': '南非', 'flag': '🇿🇦', 'continent': '非洲'},
    'CAI': {'country': '埃及', 'flag': '🇪🇬', 'continent': '非洲'},
    'LOS': {'country': '尼日利亚', 'flag': '🇳🇬', 'continent': '非洲'},
    'NBO': {'country': '肯尼亚', 'flag': '🇰🇪', 'continent': '非洲'},
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
  
  // 获取所有支持的位置代码
  static List<String> getAllLocationCodes() {
    return _locationMapping.keys.toList()..sort();
  }
  
  // 根据国家获取位置代码列表
  static List<String> getCodesByCountry(String country) {
    final codes = <String>[];
    _locationMapping.forEach((code, info) {
      if (info['country'] == country) {
        codes.add(code);
      }
    });
    return codes;
  }
  
  // 根据大洲获取位置代码列表
  static List<String> getCodesByContinent(String continent) {
    final codes = <String>[];
    _locationMapping.forEach((code, info) {
      if (info['continent'] == continent) {
        codes.add(code);
      }
    });
    return codes;
  }
}