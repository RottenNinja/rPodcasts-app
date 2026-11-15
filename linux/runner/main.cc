#include "my_application.h"

int main(int argc, char** argv) {
  // Without a session bus dconf can't save GTK settings, so keep them in memory.
  if (g_getenv("DBUS_SESSION_BUS_ADDRESS") == nullptr) {
    g_setenv("GSETTINGS_BACKEND", "memory", FALSE);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
