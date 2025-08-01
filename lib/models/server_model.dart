class ServerModel {
  final String id;
  final String name;
  final String location;
  final String ip;
  final int port;
  int ping;
  bool isSelected;

  ServerModel({
    required this.id,
    required this.name,
    required this.location,
    required this.ip,
    required this.port,
    this.ping = 0,
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
      ping: json['ping'],
      isSelected: json['isSelected'],
    );
  }
} 