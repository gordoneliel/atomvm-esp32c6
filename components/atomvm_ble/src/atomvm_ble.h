/*
 * atomvm_ble.h - BLE peripheral NIF for AtomVM on ESP32-C6
 *
 * Exposes NimBLE GATT server functionality to Erlang/Elixir via NIFs.
 * Events (connect, disconnect, subscribe, write) are delivered as
 * messages to the calling Erlang process.
 */

#ifndef ATOMVM_BLE_H
#define ATOMVM_BLE_H

#include <globalcontext.h>
#include <nifs.h>

void atomvm_ble_nif_init(GlobalContext *global);
const struct Nif *atomvm_ble_nif_get_nif(const char *nifname);

#endif /* ATOMVM_BLE_H */
