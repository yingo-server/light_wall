#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// 把一条启动期失败原因同时写到调试输出与
// `%APPDATA%\LightWall\startup_error.log`。
//
// 为什么需要：这是 GUI 子系统程序，默认没有控制台。图形环境不可用时
// （远程桌面会话、无 GPU 的虚拟机、驱动异常）进程会凭空消失，用户只看到
// "双击没反应"，无从排查。写入日志文件后至少有一个可查的证据。
void ReportStartupFailure(const wchar_t* reason);

#endif  // RUNNER_UTILS_H_
