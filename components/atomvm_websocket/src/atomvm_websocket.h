/*
 * atomvm_websocket.h - WebSocket client NIF for AtomVM on ESP32
 *
 * Wraps ESP-IDF's esp_websocket_client managed component to provide
 * WebSocket connectivity from Erlang/Elixir on AtomVM.
 */

#ifndef ATOMVM_WEBSOCKET_H
#define ATOMVM_WEBSOCKET_H

#include <globalcontext.h>
#include <nifs.h>

void atomvm_websocket_nif_init(GlobalContext *global);
const struct Nif *atomvm_websocket_nif_get_nif(const char *nifname);

#endif
