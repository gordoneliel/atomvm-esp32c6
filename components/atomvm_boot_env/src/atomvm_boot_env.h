#ifndef ATOMVM_BOOT_ENV_H
#define ATOMVM_BOOT_ENV_H

#include <globalcontext.h>
#include <nifs.h>

/**
 * Get the inactive partition name based on NVS "active" value.
 * Returns "main_a" if active is 1 (b), "main_b" if active is 0 (a).
 */
const char *get_inactive_part_name(void);

void atomvm_boot_env_nif_init(GlobalContext *global);
const struct Nif *atomvm_boot_env_nif_get_nif(const char *nifname);

#endif
