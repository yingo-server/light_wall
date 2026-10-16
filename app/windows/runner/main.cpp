#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"light_wall", origin, size)) {
    // 窗口/图形环境创建失败。Flutter Windows 会优先使用系统 GPU 后端
    // （Impeller → OpenGL ES → ANGLE → D3D11），底层栈在没有硬件 GPU 时
    // 通常会退到 WARP / 软件光栅化，但**这不是 Flutter 的保证行为**，
    // 也没有公开 API 让我们强制指定后端。
    //
    // 光照渲染本身是纯 Dart、零 GPU 依赖，所以如果你只是需要出图，
    // 请改用随包提供的 `lightwall_render.exe`（不链接 Flutter，可在
    // 任何环境运行）：
    //     lightwall_render.exe --bg wall.png --out out.png --time ...
    ReportStartupFailure(
        L"窗口创建失败：图形环境不可用（无 GPU / 远程会话 / 驱动异常）。"
        L"仅出图请改用 lightwall_render.exe。详见本文件同目录的日志。");
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
