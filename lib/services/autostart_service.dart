import 'dart:ffi';
import 'dart:io';
import 'package:win32/win32.dart';
import 'package:ffi/ffi.dart';

class AutoStartService {
  static const String _registryPath = 'Software\\Microsoft\\Windows\\CurrentVersion\\Run';
  static const String _appName = 'CFVPN';

  static bool isAutoStartEnabled() {
    final keyPath = _registryPath.toNativeUtf16();
    final hKey = HKEY_CURRENT_USER;
    final phkResult = calloc<HANDLE>();

    try {
      final result = RegOpenKeyEx(
        hKey,
        keyPath,
        0,
        KEY_READ,
        phkResult,
      );

      if (result == ERROR_SUCCESS) {
        final type = calloc<DWORD>();
        final data = calloc<BYTE>(MAX_PATH);
        final dataSize = calloc<DWORD>()..value = MAX_PATH;

        try {
          final queryResult = RegQueryValueEx(
            phkResult.value,
            _appName.toNativeUtf16(),
            nullptr,
            type,
            data,
            dataSize,
          );

          return queryResult == ERROR_SUCCESS;
        } finally {
          calloc.free(type);
          calloc.free(data);
          calloc.free(dataSize);
          RegCloseKey(phkResult.value);
        }
      }
      return false;
    } finally {
      calloc.free(keyPath);
      calloc.free(phkResult);
    }
  }

  static Future<bool> setAutoStart(bool enable) async {
    final keyPath = _registryPath.toNativeUtf16();
    final hKey = HKEY_CURRENT_USER;
    final phkResult = calloc<HANDLE>();

    try {
      final result = RegOpenKeyEx(
        hKey,
        keyPath,
        0,
        KEY_WRITE,
        phkResult,
      );

      if (result == ERROR_SUCCESS) {
        if (enable) {
          final exePath = Platform.resolvedExecutable;
          final valueData = exePath.toNativeUtf16();
          try {
            final setResult = RegSetValueEx(
              phkResult.value,
              _appName.toNativeUtf16(),
              0,
              REG_SZ,
              valueData.cast<BYTE>(),
              (exePath.length + 1) * 2,
            );
            return setResult == ERROR_SUCCESS;
          } finally {
            calloc.free(valueData);
          }
        } else {
          final deleteResult = RegDeleteValue(
            phkResult.value,
            _appName.toNativeUtf16(),
          );
          return deleteResult == ERROR_SUCCESS;
        }
      }
      return false;
    } finally {
      calloc.free(keyPath);
      RegCloseKey(phkResult.value);
      calloc.free(phkResult);
    }
  }
}