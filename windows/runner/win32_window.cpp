#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
  ZeroMemory(&tray_icon_data_, sizeof(NOTIFYICONDATA));
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                        const Point& origin,
                        const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();
  
  // 使用圆角窗口样式
  const DWORD window_style = WS_OVERLAPPEDWINDOW & ~(WS_MAXIMIZEBOX);
  
  // 创建圆角窗口
  HWND window = CreateWindowEx(
      0,  // 不使用扩展样式
      window_class,
      title.c_str(),
      window_style,
      origin.x,
      origin.y,
      size.width,
      size.height,
      nullptr,
      nullptr,
      GetModuleHandle(nullptr),
      this);
      
  if (!window) {
    return false;
  }

  // 启用圆角（Windows 11）
  OSVERSIONINFOEX osvi = { sizeof(osvi), 0, 0, 0, 0, {0}, 0, 0 };
  DWORDLONG const dwlConditionMask = VerSetConditionMask(
      VerSetConditionMask(
          VerSetConditionMask(0, VER_MAJORVERSION, VER_GREATER_EQUAL),
          VER_MINORVERSION, VER_GREATER_EQUAL),
      VER_BUILDNUMBER, VER_GREATER_EQUAL);

  osvi.dwMajorVersion = 10;
  osvi.dwMinorVersion = 0;
  osvi.dwBuildNumber = 22000;  // Windows 11最低版本号

  bool isWindows11 = VerifyVersionInfo(&osvi, VER_MAJORVERSION | VER_MINORVERSION | VER_BUILDNUMBER, dwlConditionMask);
  
  if (isWindows11) {
    DWMNCRENDERINGPOLICY policy = DWMNCRP_ENABLED;
    DwmSetWindowAttribute(window, DWMWA_NCRENDERING_POLICY, &policy, sizeof(policy));
    
    DWM_WINDOW_CORNER_PREFERENCE cornerPreference = DWMWCP_ROUND;
    DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE, 
                         &cornerPreference, sizeof(cornerPreference));
  }

  UpdateTheme(window);

  // Add tray icon when window is created
  AddTrayIcon();

  return OnCreate();
}

bool Win32Window::Show() {
  return ::ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_CLOSE:
      ShowWindow(false);
      AddTrayIcon();
      return 0;

    case WM_USER + 1:
      HandleTrayMessage(wparam, lparam);
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::ShowWindow(bool show) {
  if (window_handle_) {
    ::ShowWindow(window_handle_, show ? SW_SHOW : SW_HIDE);
  }
}

void Win32Window::AddTrayIcon() {
  if (!window_handle_ || is_tray_icon_added_) return;

  tray_icon_data_.cbSize = sizeof(NOTIFYICONDATA);
  tray_icon_data_.hWnd = window_handle_;
  tray_icon_data_.uID = 1;
  tray_icon_data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_data_.uCallbackMessage = WM_USER + 1;
  tray_icon_data_.hIcon = (HICON)LoadImage(GetModuleHandle(nullptr),
                                          MAKEINTRESOURCE(IDI_APP_ICON),
                                          IMAGE_ICON, 16, 16, LR_DEFAULTCOLOR);
  wcscpy_s(tray_icon_data_.szTip, L"CFVPN");

  Shell_NotifyIcon(NIM_ADD, &tray_icon_data_);
  is_tray_icon_added_ = true;
}

void Win32Window::RemoveTrayIcon() {
  if (!is_tray_icon_added_) return;

  Shell_NotifyIcon(NIM_DELETE, &tray_icon_data_);
  is_tray_icon_added_ = false;
}

void Win32Window::HandleTrayMessage(WPARAM wparam, LPARAM lparam) {
  if (wparam != 1) return;

  switch (lparam) {
    case WM_LBUTTONUP:
      ShowWindow(true);
      ::SetForegroundWindow(window_handle_);
      break;
    case WM_RBUTTONUP: {
      POINT pt;
      GetCursorPos(&pt);
      
      // 创建现代化的弹出菜单
      HMENU menu = CreatePopupMenu();
      
      // 设置菜单样式为现代化风格
      MENUINFO menuInfo = {0};
      menuInfo.cbSize = sizeof(MENUINFO);
      menuInfo.fMask = MIM_STYLE | MIM_APPLYTOSUBMENUS | MIM_BACKGROUND;
      menuInfo.dwStyle = MNS_NOTIFYBYPOS | MNS_AUTODISMISS;
      
      // 检查是否暗色模式
      bool isDarkMode = false;
      DWORD light_mode = 1;
      DWORD light_mode_size = sizeof(light_mode);
      RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                  kGetPreferredBrightnessRegValue, RRF_RT_REG_DWORD, 
                  nullptr, &light_mode, &light_mode_size);
      isDarkMode = (light_mode == 0);
      
      // 设置菜单背景色
      if (isDarkMode) {
        menuInfo.hbrBack = CreateSolidBrush(RGB(45, 45, 45));
      } else {
        menuInfo.hbrBack = CreateSolidBrush(RGB(250, 250, 250));
      }
      SetMenuInfo(menu, &menuInfo);
      
      // 添加带图标的菜单项
      MENUITEMINFO mii = {0};
      mii.cbSize = sizeof(MENUITEMINFO);
      mii.fMask = MIIM_STRING | MIIM_ID | MIIM_STATE;
      
      // "显示窗口" 菜单项
      mii.wID = 1;
      mii.dwTypeData = const_cast<LPWSTR>(L"    Show Window");
      mii.cch = wcslen(mii.dwTypeData);
      InsertMenuItem(menu, 0, TRUE, &mii);
      
      // 分隔线
      mii.fMask = MIIM_TYPE;
      mii.fType = MFT_SEPARATOR;
      InsertMenuItem(menu, 1, TRUE, &mii);
      
      // "退出" 菜单项
      mii.fMask = MIIM_STRING | MIIM_ID | MIIM_STATE;
      mii.wID = 2;
      mii.dwTypeData = const_cast<LPWSTR>(L"    Exit");
      mii.cch = wcslen(mii.dwTypeData);
      InsertMenuItem(menu, 2, TRUE, &mii);
      
      // 设置前台窗口以确保菜单正确显示
      SetForegroundWindow(window_handle_);
      
      // 显示菜单
      int cmd = TrackPopupMenu(menu, 
                              TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTBUTTON,
                              pt.x, pt.y, 0, window_handle_, nullptr);
      
      // 清理菜单资源
      if (menuInfo.hbrBack) {
        DeleteObject(menuInfo.hbrBack);
      }
      DestroyMenu(menu);

      // 处理菜单命令
      if (cmd == 1) {
        ShowWindow(true);
        ::SetForegroundWindow(window_handle_);
      } else if (cmd == 2) {
        RemoveTrayIcon();
        DestroyWindow(window_handle_);
        PostQuitMessage(0);
      }
      break;
    }
  }
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    RemoveTrayIcon();
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}