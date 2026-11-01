#ifndef DSH_CONTROL_TEST
#include <napi/native_api.h>
#include <AbilityKit/native_child_process.h>
#endif
#include <stdint.h>
#include <pthread.h>
#include <string.h>
#define EXIT_CAPACITY 256
struct exit_record { int32_t pid; int32_t signal; };
static struct exit_record records[EXIT_CAPACITY];
static unsigned record_count;
static int overflowed;
static pthread_mutex_t exit_mutex = PTHREAD_MUTEX_INITIALIZER;
#ifndef DSH_CONTROL_TEST
static int watching = 0;
#endif
/* 回调可能来自其他线程；记录满时保留既有结果，明确报告容量耗尽。 */
static void on_exit(int32_t pid, int32_t signal) {
 pthread_mutex_lock(&exit_mutex);
 unsigned i; for (i=0;i<record_count;i++) if(records[i].pid==pid) break;
 if(i<EXIT_CAPACITY) { records[i]=(struct exit_record){pid,signal}; if(i==record_count) record_count++; }
 else overflowed=1;
 pthread_mutex_unlock(&exit_mutex);
}
static int exit_signal(int pid) {
 pthread_mutex_lock(&exit_mutex);
 int result=overflowed ? -2 : -1;
 for(unsigned i=0;i<record_count;i++) if(records[i].pid==pid) {result=records[i].signal;break;}
 pthread_mutex_unlock(&exit_mutex);return result;
}
/* 仅释放指定PID已有退出记录，保留兄弟记录及溢出证据。 */
static int forget_exit(int pid) {
 pthread_mutex_lock(&exit_mutex);
 int removed=0;
 for(unsigned i=0;i<record_count;i++) if(records[i].pid==pid) {
  records[i]=records[--record_count]; removed=1; break;
 }
 pthread_mutex_unlock(&exit_mutex); return removed;
}
#ifndef DSH_CONTROL_TEST
static napi_value number(napi_env env, int n) { napi_value v; napi_create_int32(env,n,&v); return v; }
static int argument(napi_env env,napi_callback_info info) { size_t n=1; napi_value a; int32_t pid=-1; napi_get_cb_info(env,info,&n,&a,NULL,NULL); if(n) napi_get_value_int32(env,a,&pid); return pid; }
static napi_value reset(napi_env env,napi_callback_info info) { (void)info; pthread_mutex_lock(&exit_mutex); memset(records,0,sizeof(records)); record_count=0; overflowed=0; pthread_mutex_unlock(&exit_mutex); return number(env,0); }
static napi_value watch(napi_env env,napi_callback_info info) { (void)info; int code = watching ? 0 : OH_Ability_RegisterNativeChildProcessExitCallback(on_exit); if (!code) watching = 1; return number(env,code); }
static napi_value stop(napi_env env,napi_callback_info info) { return number(env,OH_Ability_KillChildProcess(argument(env,info))); }
static napi_value exited(napi_env env,napi_callback_info info) { return number(env,exit_signal(argument(env,info))>=0); }
static napi_value forget(napi_env env,napi_callback_info info) { return number(env,forget_exit(argument(env,info))); }
static napi_value signal_value(napi_env env,napi_callback_info info) { return number(env,exit_signal(argument(env,info))); }
static napi_value init(napi_env env,napi_value exports) {
 napi_property_descriptor p[]={{"forget",0,forget,0,0,0,napi_default,0},{"signal",0,signal_value,0,0,0,napi_default,0},{"reset",0,reset,0,0,0,napi_default,0},{"watch",0,watch,0,0,0,napi_default,0},{"stop",0,stop,0,0,0,napi_default,0},{"exited",0,exited,0,0,0,napi_default,0}};
 napi_define_properties(env,exports,6,p); return exports;
}
static napi_module module={.nm_version=1,.nm_register_func=init,.nm_modname="dsh_control"};
__attribute__((constructor)) static void register_module(void) { napi_module_register(&module); }

#endif
