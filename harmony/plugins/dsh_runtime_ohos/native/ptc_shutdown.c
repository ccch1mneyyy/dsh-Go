#define _GNU_SOURCE
#include <node_api.h>
#include <sys/socket.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
/* 只绑定固定引导器传入的已授权控制FD，不接收JS任意FD参数。 */
static int control_fd=-1;static int registered;
__attribute__((visibility("default"))) int DshPtcSetControlFd(int fd){if(registered||fd<20)return -1;registered=1;control_fd=fd;return 0;}
__attribute__((visibility("default"))) void DshPtcShutdownRegistered(void){if(control_fd>=20){shutdown(control_fd,SHUT_RDWR);control_fd=-1;}}
static napi_value shutdown_mode(napi_env env,int mode){
 int status=control_fd<20?-1:shutdown(control_fd,mode);if(mode==SHUT_RDWR)control_fd=-1;
 if(status!=0){napi_throw_error(env,"IPC_SHUTDOWN_FAILED","IPC关闭失败");return NULL;}
 napi_value result;napi_get_undefined(env,&result);return result;
}
static napi_value half(napi_env e,napi_callback_info info){(void)info;return shutdown_mode(e,SHUT_WR);}
static napi_value both(napi_env e,napi_callback_info info){(void)info;return shutdown_mode(e,SHUT_RDWR);}
static napi_value init(napi_env env,napi_value exports){
 if(control_fd<20){napi_throw_error(env,"IPC_FD_INVALID","IPC初始化失败");return NULL;}
 napi_value a,b;napi_create_function(env,"shutdownWrite",NAPI_AUTO_LENGTH,half,NULL,&a);napi_create_function(env,"shutdownBoth",NAPI_AUTO_LENGTH,both,NULL,&b);napi_set_named_property(env,exports,"shutdownWrite",a);napi_set_named_property(env,exports,"shutdownBoth",b);return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME,init)
