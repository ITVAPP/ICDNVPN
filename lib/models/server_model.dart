class ServerModel {
  final String id;
  final String name;
  final String location;
  final String ip;
  final int port;
  int ping;
  double downloadSpeed; // 添加下载速度字段 (MB/s)
  bool isSelected;

  ServerModel({
    required this.id,
    required this.name,
    required this.location,
    required this.ip,
    required this.port,
    this.ping = 0,
    this.downloadSpeed = 0.0,
    this.isSelected = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'location': location,
      'ip': ip,
      'port': port,
      'ping': ping,
      'downloadSpeed': downloadSpeed,
      'isSelected': isSelected,
    };
  }

  factory ServerModel.fromJson(Map<String, dynamic> json) {
    return ServerModel(
      id: json['id'],
      name: json['name'],
      location: json['location'],
      ip: json['ip'],
      port: json['port'],
      ping: json['ping'] ?? 0,
      downloadSpeed: (json['downloadSpeed'] ?? 0.0).toDouble(),
      isSelected: json['isSelected'] ?? false,
    );
  }
}