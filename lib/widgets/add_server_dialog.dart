import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_model.dart';
import '../providers/server_provider.dart';

class AddServerDialog extends StatefulWidget {
  const AddServerDialog({super.key});

  @override
  State<AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<AddServerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '443');

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _submitForm() {
    if (_formKey.currentState!.validate()) {
      final server = ServerModel(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: _nameController.text,
        location: _locationController.text,
        ip: _ipController.text,
        port: int.parse(_portController.text),
      );

      context.read<ServerProvider>().addServer(server);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '服务器名称'),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return '请输入服务器名称';
                }
                return null;
              },
            ),
            TextFormField(
              controller: _locationController,
              decoration: const InputDecoration(labelText: '位置'),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return '请输入位置';
                }
                return null;
              },
            ),
            TextFormField(
              controller: _ipController,
              decoration: const InputDecoration(labelText: 'IP地址'),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return '请输入IP地址';
                }
                return null;
              },
            ),
            TextFormField(
              controller: _portController,
              decoration: const InputDecoration(labelText: '端口'),
              keyboardType: TextInputType.number,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return '请输入端口';
                }
                if (int.tryParse(value) == null) {
                  return '请输入有效的端口号';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: _submitForm,
                  child: const Text('添加'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
} 