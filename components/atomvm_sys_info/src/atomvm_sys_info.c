/*
 * atomvm_sys_info.c - System info NIFs for AtomVM on ESP32
 *
 * NIFs:
 *   sys_info_nif:cpu_percent/0 - Returns CPU usage as integer 0-100
 */

#include <sdkconfig.h>
#include <string.h>

#include <atom.h>
#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <interop.h>
#include <module.h>
#include <nifs.h>
#include <portnifloader.h>
#include <term.h>

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_timer.h>

#define TAG "sys_info"

static configRUN_TIME_COUNTER_TYPE s_prev_total_time = 0;
static configRUN_TIME_COUNTER_TYPE s_prev_idle_time = 0;
static int s_last_cpu_percent = 0;

static term nif_cpu_percent(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    UNUSED(argv);

#if configGENERATE_RUN_TIME_STATS == 1
    UBaseType_t num_tasks = uxTaskGetNumberOfTasks();
    TaskStatus_t *task_array = malloc(num_tasks * sizeof(TaskStatus_t));
    if (task_array == NULL) {
        return term_from_int(s_last_cpu_percent);
    }

    configRUN_TIME_COUNTER_TYPE total_run_time;
    UBaseType_t filled = uxTaskGetSystemState(task_array, num_tasks, &total_run_time);

    if (total_run_time == 0 || filled == 0) {
        free(task_array);
        return term_from_int(0);
    }

    /* Sum idle task runtime */
    configRUN_TIME_COUNTER_TYPE idle_time = 0;
    for (UBaseType_t i = 0; i < filled; i++) {
        if (strncmp(task_array[i].pcTaskName, "IDLE", 4) == 0) {
            idle_time += task_array[i].ulRunTimeCounter;
        }
    }

    free(task_array);

    /* Delta since last call */
    configRUN_TIME_COUNTER_TYPE delta_total = total_run_time - s_prev_total_time;
    configRUN_TIME_COUNTER_TYPE delta_idle = idle_time - s_prev_idle_time;

    s_prev_total_time = total_run_time;
    s_prev_idle_time = idle_time;

    if (delta_total > 0) {
        int idle_pct = (int)((delta_idle * 100ULL) / delta_total);
        if (idle_pct > 100) idle_pct = 100;
        s_last_cpu_percent = 100 - idle_pct;
    }

    return term_from_int(s_last_cpu_percent);
#else
    return term_from_int(-1);
#endif
}

static const struct Nif cpu_percent_nif = {
    .base.type = NIFFunctionType,
    .nif_ptr = nif_cpu_percent
};

const struct Nif *atomvm_sys_info_resolve_nif(const char *nifname)
{
    if (strcmp("sys_info_nif:cpu_percent/0", nifname) == 0) {
        return &cpu_percent_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(atomvm_sys_info, NULL, NULL, atomvm_sys_info_resolve_nif)
