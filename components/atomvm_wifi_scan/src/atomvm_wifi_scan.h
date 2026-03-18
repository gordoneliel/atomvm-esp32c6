/*
 * atomvm_wifi_scan.h - WiFi scanning NIF for AtomVM on ESP32
 *
 * Provides wifi_scan_nif:scan/0 which returns a list of nearby access points.
 */

#ifndef ATOMVM_WIFI_SCAN_H
#define ATOMVM_WIFI_SCAN_H

#include <globalcontext.h>
#include <nifs.h>

void atomvm_wifi_scan_nif_init(GlobalContext *global);
const struct Nif *atomvm_wifi_scan_nif_get_nif(const char *nifname);

#endif /* ATOMVM_WIFI_SCAN_H */
