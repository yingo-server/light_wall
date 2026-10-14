//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"


#include <window_manager/window_manager_plugin_c_api.h>
#include <tray_manager/tray_manager_plugin_c_api.h>
#include <file_selector/file_selector_plugin_c_api.h>

// Registrant for each plugin.
void RegisterPlugins(flutter::PluginRegistry* registry) {
  window_manager_plugin_register_with_registrar(
      registry->GetRegistrarForPlugin("WindowManagerPlugin"));
  tray_manager_plugin_register_with_registrar(
      registry->GetRegistrarForPlugin("TrayManagerPlugin"));
  file_selector_plugin_register_with_registrar(
      registry->GetRegistrarForPlugin("FileSelectorPlugin"));
}